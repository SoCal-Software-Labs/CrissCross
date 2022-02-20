small = "small value"
{:ok, one_kb} = File.read("benchmarks/data/1kb")
{:ok, one_mb} = File.read("benchmarks/data/1mb")
{:ok, ten_mb} = File.read("benchmarks/data/10mb")

crisscross_store = fn ->
  {:ok, conn} = Redix.start_link("redis://localhost:6379")
  {:ok, store} = CrissCross.Store.Local.create(conn, nil, -1)

  store
end

{:ok, db} = SortedSetKV.open("mydb")

sled_store = fn ->
  {:ok, store} = CrissCross.Store.SledStore.create(db, nil, -1)
  {:ok, db} = CubDB.start_link(store, [])
  CubDB.put(db, "hello", "asdf")
  store
end

cql_store = fn ->
  {:ok, conn} = Xandra.start_link(nodes: ["localhost:9042"])

  {:ok, _} =
    Xandra.execute(
      conn,
      "CREATE KEYSPACE IF NOT EXISTS crisscross WITH replication = {'class': 'SimpleStrategy', 'replication_factor' : 1};"
    )

  {:ok, %Xandra.SetKeyspace{}} = Xandra.execute(conn, "USE crisscross")

  {:ok, _} =
    Xandra.execute(
      conn,
      "CREATE TABLE IF NOT EXISTS nodes (location blob PRIMARY KEY, value blob)"
    )

  {:ok, store} = CrissCross.Store.CQLStore.create(conn, nil, -1)
  store
end

# cql_store.()

{:ok, pid} =
  Supervisor.start_link([Supervisor.child_spec({Cachex, name: :node_cache}, id: :node_cache)],
    strategy: :one_for_one
  )

Benchee.run(
  %{
    "CubDB.put/3" => fn {key, value, db} ->
      for i <- 0..100 do
        CubDB.put(db, {key, i}, value)
      end

      # CubDB.file_sync(db)
    end,
    "CubDB.put_multi/3" => fn {key, value, db} ->
      vals = for i <- 0..100, do: {{key, i}, value}
      CubDB.put_multi(db, vals)
      # CubDB.file_sync(db)
    end
  },
  inputs: %{
    # "small value, auto sync" => {redis_store, small, [auto_compact: false, auto_file_sync: true]},
    # "small value" => {redis_store, small, [auto_compact: false, auto_file_sync: false]},
    # "small value file" => {file_store, small, [auto_compact: false, auto_file_sync: false]},
    "small value file crisscross" =>
      {sled_store, small, [auto_compact: false, auto_file_sync: false]},
    "ten_mb value file crisscross" =>
      {sled_store, ten_mb, [auto_compact: false, auto_file_sync: false]}
    # "small value IPFS" => {ipfs_store, small, [auto_compact: false, auto_file_sync: false]}
    # "1KB value" => {redis_store, one_kb, [auto_compact: false, auto_file_sync: false]},
    # "1MB value" => {redis_store, one_mb, [auto_compact: false, auto_file_sync: false]},
    # "10MB value" => {redis_store, ten_mb, [auto_compact: false, auto_file_sync: false]},
    # "10MB value IPFS" => {ipfs_store, ten_mb, [auto_compact: false, auto_file_sync: false]}
  },
  before_scenario: fn {store_gen, value, options} ->
    {:ok, db} = CubDB.start_link(store_gen.(), options)
    {value, db}
  end,
  before_each: fn {value, db} ->
    key = :rand.uniform(10_000)
    {key, value, db}
  end,
  after_scenario: fn {_value, db} ->
    IO.puts("#{CubDB.size(db)} entries written to database.")
    CubDB.stop(db)
  end
)
