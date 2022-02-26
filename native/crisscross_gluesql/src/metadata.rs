use {
    super::{scan_next, start_scan, MemoryStorage},
    async_trait::async_trait,
    gluesql_core::{result::Result, store::Metadata},
    std::str,
};

#[async_trait(?Send)]
impl Metadata for MemoryStorage {
    async fn schema_names(&self) -> Result<Vec<String>> {
        let tn = "__meta__".to_string();
        let pid = start_scan(self.pid, &"__meta__".as_bytes().to_vec()).await?;

        let mut names = Vec::new();

        loop {
            match scan_next(tn.clone(), pid).await? {
                Some((v, _)) => names.push(
                    str::from_utf8(&v.id[..])
                        .expect("Table name should be string")
                        .into(),
                ),
                None => break,
            }
        }

        names.sort();

        Ok(names)
    }
}
