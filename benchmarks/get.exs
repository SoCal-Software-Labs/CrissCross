data_dir = "tmp/bm_get"

cleanup = fn ->
  with {:ok, files} <- File.ls(data_dir) do
    for file <- files, do: File.rm(Path.join(data_dir, file))
    File.rmdir(data_dir)
  end
end

crisscross_store = fn hash, ttl ->
  {:ok, conn} = Redix.start_link("redis://localhost:6379")
  {:ok, store} = CrissCross.Store.Local.create(conn, hash, ttl)

  store
end

small = "small value"
{:ok, one_kb} = File.read("benchmarks/data/1kb")
{:ok, one_mb} = File.read("benchmarks/data/1mb")
{:ok, ten_mb} = File.read("benchmarks/data/10mb")
n = 100

{:ok, pid} =
  Supervisor.start_link([Supervisor.child_spec({Cachex, name: :node_cache}, id: :node_cache)],
    strategy: :one_for_one
  )

Benchee.run(
  %{
    "CubDB.get/3" => fn {key, db} ->
      CubDB.get(db, key)
    end
  },
  inputs: %{
    "small value" => {crisscross_store, small},
    "1KB value" => {crisscross_store, one_kb},
    "1MB value" => {crisscross_store, one_mb},
    "10MB value" => {crisscross_store, ten_mb}
    # "small value ipfs" => {ipfs_store, small},
    # "small value mldht_store" => {mldht_store, small}
    # " value" => one_kb,
    # " value" => one_mb,
    # "10MB value" => ten_mb
  },
  before_scenario: fn {mk_store, input} ->
    store = mk_store.(nil, -1)
    {:ok, db} = CubDB.start_link(store, auto_file_sync: false, auto_compact: false)
    for key <- 0..n, do: CubDB.put(db, key, input)
    {{_, loc}, _} = CubDB.Store.get_latest_header(store)
    {:ok, db} = CubDB.start_link(mk_store.(loc, -1), auto_file_sync: false, auto_compact: false)
    db
  end,
  before_each: fn db ->
    key = :rand.uniform(n)
    {key, db}
  end,
  after_scenario: fn db ->
    CubDB.stop(db)
    cleanup.()
  end
)
