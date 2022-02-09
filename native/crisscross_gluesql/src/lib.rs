pub mod atoms;

mod alter_table;
mod index;
mod metadata;
mod transaction;

use {
    async_trait::async_trait,
    gluesql_core::{
        data::{Row, Schema},
        result::{MutResult, Result, TrySelf},
        store::{GStore, GStoreMut, RowIter, Store, StoreMut},
    },
    gluesql::core::result::Error,
    gluesql::prelude::*,
    rustler::Encoder,
    serde::{Deserialize, Serialize},
    serde_json::value::Value,
    serde_rustler::{to_term},
    std::{
        str,
        result::Result as RealResult,
        collections::{BTreeMap, HashMap},
        iter::empty,
        io::Write,
        sync::{
            mpsc,
            Mutex
        }
    },
    uuid::Uuid,
};

#[derive(Debug, Clone)]
pub struct Key {
    pub table_name: String,
    pub id: Vec<u8>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Item {
    pub schema: Schema,
    pub rows: BTreeMap<u64, Row>,
}

#[derive(Clone)]
pub struct MemoryStorage {
    pub pid: rustler::types::Pid
}

#[async_trait(?Send)]
impl Store<Key> for MemoryStorage {
    async fn fetch_schema(&self, table_name: &str) -> Result<Option<Schema>> {
        match get_row(self.pid, "__meta__".as_bytes(), table_name.as_bytes().to_vec())
            .await? {
               Some(b) => 
                match bincode::deserialize(&b[..]) {
                    Ok(v) => Ok(Some(v)),
                    Err(e) => Err(Error::StorageMsg("Failed to decode schema".into()))
                }
               None => Ok(None)
            }

    }

    async fn scan_data(&self, table_name: &str) -> Result<RowIter<Key>> {
        let pid = start_scan(self.pid, table_name.as_bytes()).await?;
        let tn = table_name.to_string();
        let mut data = Vec::new();

        loop {
            match scan_next(tn.clone(), pid).await? {
                Some(v) => data.push(Ok(v)),
                None => break
            }
        };

        Ok(Box::new(data.into_iter()))
    }
}

#[async_trait(?Send)]
impl StoreMut<Key> for MemoryStorage {
    async fn insert_schema(self, schema: &Schema) -> MutResult<Self, ()> {
        let table_name = schema.table_name.clone();
        let item = Item {
            schema: schema.clone(),
            rows: BTreeMap::new(),
        };
        let bin =
            match bincode::serialize(&item) {
                Ok(b) => b, 
                Err(_err) => panic!("Unable to serialize")
            };

        put_rows(self.pid, "__meta__".as_bytes(), vec![(table_name.as_bytes().to_vec(), bin)]).await.try_self(self)
    }

    async fn delete_schema(self, table_name: &str) -> MutResult<Self, ()> {
        delete_rows(self.pid, "__meta__".as_bytes(), vec![table_name.as_bytes().to_vec()]).await.try_self(self)
    }

    async fn insert_data(self, table_name: &str, rows: Vec<Row>) -> MutResult<Self, ()> {
        let to_insert =
            rows
            .iter()
            .map(|row| {
                let bin =
                    match bincode::serialize(row) {
                        Ok(b) => b, 
                        Err(_) => panic!("Unable to serialize")
                    };

                (Uuid::new_v4().as_bytes().to_vec(), bin)
            })
            .collect();

        put_rows(self.pid, table_name.as_bytes(), to_insert).await.try_self(self)
    }

    async fn update_data(self, table_name: &str, rows: Vec<(Key, Row)>) -> MutResult<Self, ()> {
        let to_insert =
            rows
            .iter()
            .map(|(key, row)| {
                let bin =
                    match bincode::serialize(row) {
                        Ok(b) => b, 
                        Err(_) => panic!("Unable to serialize")
                    };

                (key.id.clone(), bin)
            })
            .collect();

        put_rows(self.pid, table_name.as_bytes(), to_insert).await.try_self(self)
    }

    async fn delete_data(self, table_name: &str, keys: Vec<Key>) -> MutResult<Self, ()> {
        let to_delete =
            keys
            .iter()
            .map(|key| {
                key.id.clone()
            })
            .collect();

        delete_rows(self.pid, "__meta__".as_bytes(), to_delete).await.try_self(self)
    }
}

impl GStore<Key> for MemoryStorage {}
impl GStoreMut<Key> for MemoryStorage {}

pub struct CallbackToken {
    pub continue_signal: async_channel::Sender<(bool, Option<(Vec<u8>, Vec<u8>)>)>,
}

pub struct ScanCallbackToken {
    pub continue_signal: async_channel::Sender<(bool, rustler::types::Pid, Vec<u8>)>,
}

pub struct CallPayload {
    pub payload: Vec<u8>,
    pub env: rustler::env::OwnedEnv,
    pub reference: rustler::env::SavedTerm,
    pub pid: rustler::types::Pid
}

pub struct SenderResource {
    pub sender: Mutex<mpsc::Sender<Option<CallPayload>>>,
}

pub struct CallbackTokenResource {
    pub token: CallbackToken,
}

pub struct ScanCallbackTokenResource {
    pub token: ScanCallbackToken,
}

#[rustler::nif]
fn start_sql<'a>(env: rustler::Env<'a>, pid: rustler::types::Pid, reference: rustler::Term<'a>,) -> rustler::Term<'a> {
    let owned_env = rustler::env::OwnedEnv::new();
    let saved_term = owned_env.save(reference);
    let env_pid = env.pid().clone();

    std::thread::spawn(move || {
        let storage = MemoryStorage{pid: pid};
        let mut glue = Glue::new(storage);

        let (tx, rx) = mpsc::channel::<Option<CallPayload>>();
        let mut msg_env = rustler::OwnedEnv::new();

        msg_env.send_and_clear(&env_pid, |env| {
            let hydrated_reference = owned_env.run(|inner_env| {
                let term = saved_term.load(inner_env);
                term.in_env(env)
            });
            (
                atoms::ok(),
                rustler::ResourceArc::new(SenderResource {
                    sender: Mutex::new(tx),
                }),
                hydrated_reference,
            )
                .encode(env)

        });

        for msg in rx {
            match msg {
                Some(caller) => {
                    let mut msg_env = rustler::OwnedEnv::new();
                    msg_env.send_and_clear(&(caller.pid), |env| {
                        let hydrated_reference = caller.env.run(|inner_env| {
                            let term = caller.reference.load(inner_env);
                            term.in_env(env)
                        });

                        let s = match str::from_utf8(&caller.payload) {
                            Ok(v) => v,
                            Err(e) => panic!("Invalid UTF-8 sequence: {}", e),
                        };
                    
                        match glue.execute(s) {
                            Ok(statement_result) => {

                                // let mut bin =
                                //     match rustler::OwnedBinary::new(result.len()) {
                                //         Some(bin) => bin,
                                //         None => {
                                //             panic!("binary term allocation fail")
                                //         }
                                //     };

                                // bin.as_mut_slice()
                                // .write_all(&result.as_bytes()[..])
                                // .expect("memory copy of string failed");

                                match serde_json::to_value(statement_result) {
                                    Ok(result) =>
                                        match to_term(env, result) {
                                            Ok(term) => {
                                                (atoms::ok(), term, hydrated_reference)
                                                .encode(env)
                                            },
                                            Err(e) => {
                                                (atoms::error(), e.to_string(), hydrated_reference)
                                                    .encode(env)
                                            }
                                        },
                                    Err(e) => {
                                                (atoms::error(), e.to_string(), hydrated_reference)
                                                    .encode(env)
                                            }
                                }
                                
                            }
                            Err(e) => {
                                (atoms::error(), e.to_string(), hydrated_reference)
                                    .encode(env)
                            }
                        }
                    });

                }
                None => break,
            }
        }
    });

    atoms::ok().encode(env)
}

#[rustler::nif]
fn stop<'a>(sender: rustler::Term<'a>) -> RealResult<rustler::Atom, rustler::Error> {
    let sender_resource: rustler::ResourceArc<SenderResource> = sender.decode()?;
    let sender = sender_resource.sender.lock().unwrap();

    sender.send(None).expect("Error closing server");
    Ok(atoms::ok())
}

#[rustler::nif]
fn execute<'a>(
    sender: rustler::Term<'a>,
    pid: rustler::types::Pid,
    reference: rustler::Term<'a>,
    payload: rustler::types::Binary,
) -> RealResult<rustler::Atom, rustler::Error> {
    let sender_resource: rustler::ResourceArc<SenderResource> = sender.decode()?;
    let sender = sender_resource.sender.lock().unwrap();
    let owned_env = rustler::env::OwnedEnv::new();
    let saved_term = owned_env.save(reference);
    sender
        .send(Some(CallPayload {
            payload: payload.as_slice().to_vec(),
            reference: saved_term,
            env: owned_env,
            pid: pid,
        }))
        .unwrap();
    Ok(atoms::ok())
}

#[rustler::nif]
fn receive_result<'a>(
    token: rustler::Term<'a>,
    success: bool,
    has_key: bool,
    key: rustler::types::Binary,
    result: rustler::types::Binary,
) -> RealResult<rustler::Atom, rustler::Error> {
    let token_resource: rustler::ResourceArc<CallbackTokenResource> = token.decode()?;
    let results = if success {
        if has_key {
            (true, Some((key.as_slice().to_vec(), result.as_slice().to_vec())))
        } else {
            (true, None)
        }
        
    } else {
        (false, Some(("".into(), result.as_slice().to_vec())))
    };

    token_resource.token.continue_signal.try_send(results).expect("Error sending result");

    Ok(atoms::ok())
}

#[rustler::nif]
fn receive_pid_result<'a>(
    token: rustler::Term<'a>,
    success: bool,
    pid: rustler::types::Pid,
    error: rustler::types::Binary,
) -> RealResult<rustler::Atom, rustler::Error> {
    let token_resource: rustler::ResourceArc<ScanCallbackTokenResource> = token.decode()?;
    let results = if success {
        (true, pid, error.as_slice().to_vec())
    } else {
        (false, pid, error.as_slice().to_vec())
    };

    token_resource.token.continue_signal.try_send(results).expect("Error sending result");

    Ok(atoms::ok())
}

async fn put_rows(pid: rustler::types::Pid, table: &[u8], values: Vec<(Vec<u8>, Vec<u8>)>) -> Result<()> {
    let (signal, get_result) = async_channel::unbounded::<(bool, Option<(Vec<u8>, Vec<u8>)>)>();

    let token = CallbackToken {
        continue_signal: signal,
    };

    let callback_token =
        rustler::resource::ResourceArc::new(CallbackTokenResource {
            token: token,
        });

    let mut msg_env = rustler::OwnedEnv::new();
    msg_env.send_and_clear(&pid, |env| {
        (
            atoms::put(),
            table,
            values,
            callback_token
        )
            .encode(env)
    });

    let option_res = get_result.recv().await;

    match option_res {
        Ok(res) => {
            let (success, r): (bool, Option<(Vec<u8>, Vec<u8>)>) = res;
            match success {
                true => Ok(()),
                false => Err(Error::StorageMsg(format!(
                    "Foreign PUT to Elixir Failed: {:?}",
                    r
                )
                .into())),
            }  
        }
        Err(_) => Err(Error::StorageMsg(format!(
                    "Foreign PUT To Elixir Failed"
                )
                .into()))
    }
}

async fn delete_rows(pid: rustler::types::Pid, table: &[u8], values: Vec<Vec<u8>>) -> Result<()> {
    let (signal, get_result) = async_channel::unbounded::<(bool, Option<(Vec<u8>, Vec<u8>)>)>();

    let token = CallbackToken {
        continue_signal: signal,
    };

    let callback_token =
        rustler::resource::ResourceArc::new(CallbackTokenResource {
            token: token,
        });

    let mut msg_env = rustler::OwnedEnv::new();
    msg_env.send_and_clear(&pid, |env| {
        (
            atoms::delete(),
            table,
            values,
            callback_token
        )
            .encode(env)
    });

    let option_res = get_result.recv().await;

    match option_res {
        Ok(res) => {
            let (success, r): (bool, Option<(Vec<u8>, Vec<u8>)>) = res;
            match success {
                true => Ok(()),
                false => Err(Error::StorageMsg(format!(
                    "Foreign DELETE to Elixir Failed: {:?}",
                    r
                )
                .into())),
            }  
        }
        Err(_) => Err(Error::StorageMsg(format!(
                    "Foreign DELETE To Elixir Failed"
                )
                .into()))
    }
}


async fn get_row(pid: rustler::types::Pid, table: &[u8], value: Vec<u8>) -> Result<Option<Vec<u8>>> {
    let (signal, get_result) = async_channel::unbounded::<(bool, Option<(Vec<u8>, Vec<u8>)>)>();

    let token = CallbackToken {
        continue_signal: signal,
    };

    let callback_token =
        rustler::resource::ResourceArc::new(CallbackTokenResource {
            token: token,
        });

    let mut msg_env = rustler::OwnedEnv::new();
    msg_env.send_and_clear(&pid, |env| {
        (
            atoms::get(),
            table,
            value,
            callback_token
        )
            .encode(env)
    });

    let option_res = get_result.recv().await;

    match option_res {
        Ok(res) => {
            let (success, r): (bool, Option<(Vec<u8>, Vec<u8>)>) = res;
            match success {
                true => 
                    match r {
                        Some((_key, result)) => Ok(Some(result)),
                        None => Ok(None)
                    }
                false => Err(Error::StorageMsg(format!(
                    "Foreign GET to Elixir Failed: {:?}",
                    r
                )
                .into())),
            }  
        }
        Err(_) => Err(Error::StorageMsg(format!(
                    "Foreign GET To Elixir Failed"
                )
                .into()))
    }
}

async fn start_scan(pid: rustler::types::Pid, table: &[u8]) -> Result<rustler::types::Pid> {
    let (signal, get_result) = async_channel::unbounded::<(bool, rustler::types::Pid, Vec<u8>)>();

    let token = ScanCallbackToken {
        continue_signal: signal,
    };

    let callback_token =
        rustler::resource::ResourceArc::new(ScanCallbackTokenResource {
            token: token,
        });

    let mut msg_env = rustler::OwnedEnv::new();
    msg_env.send_and_clear(&pid, |env| {
        (
            atoms::start_scan(),
            table,
            callback_token
        )
            .encode(env)
    });

    let option_res = get_result.recv().await;

    match option_res {
        Ok(res) => {
            let (success, pid, result): (bool, rustler::types::Pid, Vec<u8>) = res;
            match success {
                true => Ok(pid),
                false => Err(Error::StorageMsg(format!(
                    "Foreign GET to Elixir Failed: {:?}",
                    std::str::from_utf8(&result).unwrap_or(&"")
                )
                .into())),
            }  
        }
        Err(_) => Err(Error::StorageMsg(format!(
                    "Foreign GET To Elixir Failed"
                )
                .into()))
    }
}

async fn scan_next(table_name: String, pid: rustler::types::Pid) -> Result<Option<(Key, Row)>> {
    let (signal, get_result) = async_channel::unbounded::<(bool, Option<(Vec<u8>, Vec<u8>)>)>();

    let token = CallbackToken {
        continue_signal: signal,
    };

    let callback_token =
        rustler::resource::ResourceArc::new(CallbackTokenResource {
            token: token,
        });

    let mut msg_env = rustler::OwnedEnv::new();
    msg_env.send_and_clear(&pid, |env| {
        (
            atoms::scan_next(),
            callback_token
        )
            .encode(env)
    });

    let option_res = get_result.recv().await;

    match option_res {
        Ok(res) => {
            let (success, res): (bool, Option<(Vec<u8>, Vec<u8>)>) = res;
            match success {
                true => 
                    match res {
                        Some((key, r)) =>
                            match bincode::deserialize(&r[..]) {
                                Ok(row) => Ok(Some((Key {table_name: table_name, id: key}, row))),
                                Err(e) => Err(Error::StorageMsg(format!(
                                            "Failed to decode row: {:?}",
                                            e
                                        )))
                            },
                        None =>
                            Ok(None)
                    },
                false => Err(Error::StorageMsg(format!(
                    "Foreign GET to Elixir Failed: {:?}",
                    res
                )
                .into())),
            }  
        }
        Err(_) => Err(Error::StorageMsg(format!(
                    "Foreign GET To Elixir Failed"
                )
                .into()))
    }
}

fn load(env: rustler::Env, _info: rustler::Term) -> bool {
    rustler::resource!(SenderResource, env);
    rustler::resource!(CallbackTokenResource, env);
    rustler::resource!(ScanCallbackTokenResource, env);
    true
}

rustler::init!("Elixir.CrissCross.GlueSql", [start_sql, stop, execute, receive_pid_result, receive_result], load = load);
