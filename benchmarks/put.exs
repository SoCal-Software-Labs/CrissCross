small = "small value"
{:ok, one_kb} = File.read("benchmarks/data/1kb")
{:ok, one_mb} = File.read("benchmarks/data/1mb")
{:ok, ten_mb} = File.read("benchmarks/data/10mb")

redis_store = fn ->
  {:ok, store} = CrissCross.Store.Redis.create([host: "localhost", port: 6379], "1")
  store
end

file_store = fn ->
  {:ok, store} = CubDB.Store.File.create("dir")
  store
end

mldht_store = fn ->
  cluster = "CsFD25YQcZ6N179edKvhRkV9Nv75gjL6MwV16z5frniQ" |> MlDHT.Server.Utils.decode_human!()
  {rsa_priv_key, rsa_pub_key} = MlDHT.generate_store_keypair()
  {:ok, encoded} = ExPublicKey.pem_encode(rsa_pub_key)
  {pub_key_hash, _} = MlDHT.store(cluster, encoded, -1)
  {:ok, store} = CrissCross.Store.MlDHTStore.create(cluster, rsa_priv_key)

  store
end

ipfs_store = fn ->
  put_client = CrissCross.Store.IPFS.ipfs_client("http://localhost:5001")
  get_client = CrissCross.Store.IPFS.ipfs_client("http://localhost:5001")

  {:ok, store} =
    CrissCross.Store.IPFS.create(
      put_client,
      get_client,
      [host: "localhost", port: 6379],
      "3",
      true
    )

  store
end

{:ok, pid} =
  Supervisor.start_link(
    [
      Supervisor.child_spec(
        {Finch,
         name: MyFinch,
         pools: %{
           "http://localhost:5001" => [size: 100]
         }},
        id: :my_finch
      ),
      {Finch,
       name: MyFinchPut,
       pools: %{
         "http://localhost:5001" => [size: 100]
       }}
    ],
    strategy: :one_for_one
  )

Benchee.run(
  %{
    "CubDB.put/3" => fn {key, value, db} ->
      for i <- 0..100 do
        CubDB.put(db, {key, i}, value)
      end

      # CubDB.file_sync(db)
    end
  },
  inputs: %{
    # "small value, auto sync" => {redis_store, small, [auto_compact: false, auto_file_sync: true]},
    # "small value" => {redis_store, small, [auto_compact: false, auto_file_sync: false]},
    # "small value file" => {file_store, small, [auto_compact: false, auto_file_sync: false]},
    "small value file mldht_store" =>
      {mldht_store, small, [auto_compact: false, auto_file_sync: false]}
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
