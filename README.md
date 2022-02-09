# CrissCross

CrissCross is a distributed key-value database written in Elixir which backups up to IPFS. It is built on an immutable btree design backed by the Interplanetary FileSystem. Each node in the tree is a seperate file on IPFS.

This project allows you to distribute a hash to clients and your application can read and query data without loading the whole database into memory. Even better the client will read data from IPFS meaning the more people connecting and using the data, the more bandwidth is provided to the dataset.


```bash
voodoospace clone <cluster> <tree_hash>
voodoospace byte_size <cluster> <tree_hash> --remote-only
voodoospace find_key <cluster> <tree_hash> <key> --remote-only
voodoospace find_pointer <cluster> <public_key> <generation>
voodoospace set_pointer <cluster> <private_key> <public_key> <tree_hash>
```

## Drawbacks

Obviously speed is the biggest factor here. Even worse is that 

## CubDB

This project uses a modified version of [CubDB](https://github.com/lucaong/cubdb). This just exposes the already well designed Storage interface and connects it to different backends.

## Distributing Latest Header

After updating the database, you will have a new hash which represents the root of the tree which backs the database. You will need to distribute this key so that others can find your database.

## Single Writer

Only one writer can write to a tree at a time. To coordinate between nodes, consider using [RedLock](https://github.com/lyokato/redlock) or other distributed locking package.


## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `iron_cub` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:iron_cub, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/iron_cub](https://hexdocs.pm/iron_cub).

