## Redis client usage

You can use any client to connect to a CrissCross server. Some commands require the elements be encoded in the erlang BERT format. 

The Pyhon client is a very thin wrapper around the Redis interface. For more information see there: https://github.com/SoCal-Software-Labs/crisscross_py/blob/main/crisscross.py

There is nothing special about using the Elixir client here. Any redis client should work.

## Connecting

Connect to your local CrissCross cluster's `INTERNAL_TCP_PORT` by using a redis client

```elixir
{:ok, conn} = Redix.start_link("redis://localhost:11111")
```

## Basic Usage

```elixir
ttl = to_string(1000 * 60 * 60 * 60 * 24) ## 24 Hours
## The BIN suffix commands dont need converting to BERT format
{:ok, location} = Redix.command(conn, ["SETMULTIBIN", "", ttl, "hello", "world"])
{:ok, location2} = Redix.command(conn, ["SETMULTIBIN", location, ttl, "hello2", "world2"])
{:ok, results} = Redix.command(conn, ["GETMULTIBIN", location, "hello", "hello2"])
```

## Storing Elixir Terms

```elixir
## Store erlang terms
key = :erlang.term_to_binary({:hello, 1})
value = :erlang.term_to_binary(%{store: [123, 123123.2, "213"]})
{:ok, location} = Redix.command(conn, ["SETMULTI", "", ttl, key, value])
{:ok, result} = Redix.command(conn, ["FETCH", location, key])
# Convert Result
:erlang.binary_to_term(result)
# GETMULTI returns results in a flat list
{:ok, results} = Redix.command(conn, ["GETMULTI", location, key])
## Convert the results to erlang terms
Enum.map(results, &:erlang.binary_to_term/1)
|> Enum.chunk_every(2)
|> Enum.map(fn [k, v] -> {k, v} end)
|> Enum.into(%{})
```

## SQL

```
{:ok, [loc | results]} = Redix.command(conn, ["SQL", "", ttl, "DROP TABLE IF EXISTS Glue;", "CREATE TABLE Glue (id INTEGER);", "INSERT INTO Glue VALUES (100);", "INSERT INTO Glue VALUES (200);", "SELECT * FROM Glue WHERE id > 100;"])
## Convert the results to erlang terms
Enum.map(results, &:erlang.binary_to_term/1)

## SQLRead doesn't return a location
{:ok, results} = Redix.command(conn, ["SQLREAD", "", "SELECT * FROM Glue WHERE id > 100;"])
Enum.map(results, &:erlang.binary_to_term/1)
```
## Cluster

```
{:ok, [name, cypher, pubkey, privkey]} = Redix.command(conn, ["CLUSTER"])
```

## Keys and pointers:

```elixir
{:ok, location} = Redix.command(conn, ["SETMULTI", "", "hello", "world"])
{:ok, [_pub, private_string]} = Redix.command(conn, ["KEYPAIR"])
{:ok, name} = Redix.command(conn, ["POINTERSET", cluster, private_string, location, "100000"])
Redix.command(conn, ["POINTERLOOKUP", cluster, name, "0"])
```

## Working with Vars and REMOTE

```elixir
Redix.command(conn, ["VARSET", "boom", loc])
Redix.command(conn, ["VARWITH", "boom", "SQL_JSON", "SELECT * FROM Glue WHERE id > 100;"])
Redix.command(conn, ["VARWITH", "boom", "REMOTE", cluster, "2", "SQL_JSON", "SELECT * FROM Glue WHERE id > 100;"])
Redix.command(conn, ["REMOTE", cluster, "2", "SQL_JSON", loc, "SELECT * FROM Glue WHERE id > 100;"])
```
