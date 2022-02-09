data_dir = "tmp/bm_get"

cleanup = fn ->
  with {:ok, files} <- File.ls(data_dir) do
    for file <- files, do: File.rm(Path.join(data_dir, file))
    File.rmdir(data_dir)
  end
end

redis_store = fn ->
  {:ok, store} = CrissCross.Store.Redis.create([host: "localhost", port: 6379], "1")
  store
end

ipfs_store = fn ->
  put_client = CrissCross.Store.IPFS.ipfs_client("http://localhost:9094")
  get_client = CrissCross.Store.IPFS.ipfs_client("http://localhost:8080")

  {:ok, store} =
    CrissCross.Store.IPFS.create(
      put_client,
      get_client,
      [host: "localhost", port: 6379],
      "3",
      false
    )

  store
end

Process.sleep(10_000)

mldht_store = fn ->
  cluster = "CsFD25YQcZ6N179edKvhRkV9Nv75gjL6MwV16z5frniQ" |> MlDHT.Server.Utils.decode_human!()
  {rsa_priv_key, rsa_pub_key} = MlDHT.generate_store_keypair()
  {:ok, encoded} = ExPublicKey.pem_encode(rsa_pub_key)
  {pub_key_hash, _} = MlDHT.store(cluster, encoded, -1)
  {:ok, store} = CrissCross.Store.MlDHTStore.create(cluster, rsa_priv_key)

  store
end

small = "small value"
{:ok, one_kb} = File.read("benchmarks/data/1kb")
{:ok, one_mb} = File.read("benchmarks/data/1mb")
{:ok, ten_mb} = File.read("benchmarks/data/10mb")
n = 100

{:ok, pid} = Supervisor.start_link([{Finch, name: MyFinch}], strategy: :one_for_one)

Benchee.run(
  %{
    "CubDB.get/3" => fn {key, db} ->
      CubDB.get(db, key)
    end
  },
  inputs: %{
    "small value" => {redis_store, small},
    # "small value ipfs" => {ipfs_store, small},
    "small value mldht_store" => {mldht_store, small}
    # "1KB value" => one_kb,
    # "1MB value" => one_mb,
    # "10MB value" => ten_mb
  },
  before_scenario: fn {store, input} ->
    {:ok, db} = CubDB.start_link(store.(), auto_file_sync: false, auto_compact: false)
    for key <- 0..n, do: CubDB.put(db, key, input)
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
