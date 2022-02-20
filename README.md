# CrissCross - Like if IPFS was also a Real-Time Distributed Computing Network

CrissCross is a new way to share immutable structures and call remote procedures. Build a tree, get a hash and distribute it in your own private cluster. Generate a key and advertise a service on the cluster. Connect with any language that has a redis client. Store data in high speed databases.

## Status

This is alpha software. Expect bugs and API changes. Please make an issue for any discussion or proposals.

# Why?

IPFS was built for files and the Web. Its API is HTTP, its abstraction is files. This datamodel is not quite right for building applications and sharing state. It is painfully slow to access from other languages and it is complex to access the underlying DAG to get raw block access.

In applications you need to manipulate *data* not files. Trees of integers, lists, maps, strings and tuples. Thus CrissCross was born. CrissCross is like IPFS, you get immutable data from a hash via P2P. However with CrissCross you talk with the Redis Protocol for maximum performance as well as insert polymorphic data in a btree instead of uploading files.

CrissCross is built to query data on remote machines without downloading the whole tree. In addition, when a tree is updated, as long as you have the old data you only have to download the new nodes of the tree. This will make downloading terabyte sized trees easy.

Another important consideration is that CrissCross is private. IPFS on the otherhand is a public network where everyone is on the same DHT. CrissCross consists of virtual clusters. There is one shared overlay network that bootstraps you into your cluster. Inside your cluster the data stays private and encrypted over the wire. You can even supply your own overlay cluster and bootstrap nodes for maximum privacy.

# Features

* Content-Addressable Immutable Key Value Trees, SQL Engine and File System
* Private Clusters - Setup a cluster of nodes to securely share trees between them
* Store polymorphic data like lists, integers, dictionaries and tuples
* Broadcast data to the network preemptively - Collaborative caching
* Configurable Maximum TTL for each cluster - Store data for as long as you need
* Simple clear protocol - Access from any language that has a Redis client
* Fast downloads with multiple connections
* Remotely access trees on other peoples machines to clone or query
* IPNS-like mutable pointers
* Encryption per cluster
* Efficiently iterate over large collections
* Built in high performance embedded database or use any Redis compatible DB

## Related Packages

* [CrissCrossDHT](https://github.com/SoCal-Software-Labs/CrissCrossDHT) A Kademlia Distributed Hash Table
* [SortedSetKV](https://github.com/SoCal-Software-Labs/SortedSetKV) High-Performance binding for the Sled Database
* [ExSchnorr](https://github.com/hansonkd/ex_schnorr) Cryptographic Signatures
* [CrissCrossPy](https://github.com/SoCal-Software-Labs/crisscross_py) Python client for CrissCross

# Tour

### Docker script

CrissCross comes distributed as a script which launches docker container for the CrissCross server.

```bash
curl https://raw.githubusercontent.com/SoCal-Software-Labs/CrissCross/main/launch_crisscross_server.sh -o ./launch_criss_cross.sh
chmod +x ./launch_criss_cross.sh
```

And finally execute the command to launch the database and server to connect to the overlay. By default CrissCross will store data in `./data` and will look for cluster configurations in `./clusters` of the directory you launch the script in.

```bash
./launch_criss_cross.sh
```

Install the command-line client with pip:

```bash
pip install crisscross-py
```

## Manipulating Trees

With CrissCross you insert data into a hash and get a new hash in return. To start a new tree, insert into an empty hash.


#### Bash

```bash 
$ MYVAR=$(crisscross put "" "hello" "world")
# In the bash you get the Base58 Representation
$ echo $MYVAR
2UPodno55iocZqNGGav5MXi6LsFFqqzDvgQm5A9Qr3pebns
$ crisscross get $MYVAR "hello"
world
```

#### Programatic Access

You can access the tree programmatically with Python (or any Redis client):

Store arbitrary data... tuples, lists, dictionaries, booleans, integers, floats and atoms. Not just binary text:

```python
>>> client = CrissCross()
>>> location = client.put_multi("", [(("wow", 1.2), {1: (True, None)})])
>>> client.get_multi(location, [("wow", 1.2)])
{1: (True, None)}
``````

## Updates

Update a tree by referencing the hash of its previous state:


#### Bash

```bash 
$ crisscross put $MYVAR "hello2" "world2"
2UPe9oukYYpPvjGthmyazd1CtTQwddc1DNRxWykdxaXuE6M
```

## Cluster Basics

A cluster consists of 4 immutable pieces of information. There is a PrivateKey which gives the holder permission to ask the cluster to store data. There is the public key that cluster members use to verify the private key. A Cypher is used to encrypt all cluster DHT traffic over the wire. Think of a Cypher as the password to talk to the cluster. Finally there is the Name, which is a Hash of the Cypher and Public keys combined. A user configurable MaxTTL can be set per node and is not cluster wide.

```bash
$ crisscross cluster
Name:       2UPkZmzFeeux8C5kVgVXRWMomgZfdHZ4yv2SqndCLrM4PNX
Cypher:     6NDdi5uVtPszZMHTYxt3n7rSiovLuMF1fQJtioz79ND2
PublicKey:  2bDkyNhW9LBRDFpU18XHCY4LiCGTvrBbtyef2YLLQNztv6qW2TQJB98
PrivateKey: wnpv357S2QpEPQTBMehzvf68uTezpnC36XS6XxFxu6nfwFNqaiZFW28x94ELF3JgHxFSyrqx6BUuE3KBpwgoQjEwLkPie5URph
MaxTTL:     86400000
```

Put this into a yaml file inside a `clusters` folder

```bash
$ crisscross cluster > clusters/my_cluster.yaml
```

Restart the node so that it picks up the configuration. Now you will be able to announce data to your new cluster. Starting a variable with `*` causes the system to load a yaml file and replace the value in your command.

```bash
# Reference the cluster name 
$ crisscross announce *clusters/my_cluster.yaml#Name 2UPe9oukYYpPvjGthmyazd1CtTQwddc1DNRxWykdxaXuE6M
True
```

You can distribute this YAML file to anybody you wish to join the cluster. Be careful who you give the Private key to as they can push data to the cluster.


## Clone and Share Trees

Once you have a hash, you can share it on the network and others can clone it from you. `*defaultcluster` is a special string that is replaced with the name of the default bootstrap overlay cluster

```bash
# On one machine
$ crisscross announce *defaultcluster 2UPe9oukYYpPvjGthmyazd1CtTQwddc1DNRxWykdxaXuE6M
True
```

```bash
# On other machine query the tree without fully downloading it
$ crisscross remote_get *defaultcluster 2UPe9oukYYpPvjGthmyazd1CtTQwddc1DNRxWykdxaXuE6M "hello2"
"world2"
# They can clone the tree to get a local copy
$ crisscross remote_persist *defaultcluster 2UPe9oukYYpPvjGthmyazd1CtTQwddc1DNRxWykdxaXuE6M
True
$ crisscross get 2UPe9oukYYpPvjGthmyazd1CtTQwddc1DNRxWykdxaXuE6M "hello"
"world"
```

## Premptively Storing Data on a Cluster

One thing CrissCross does differently than IPFS is preemptive distribution. If you have the PrivateKey, you can ask the cluster to store your tree. When you push a tree, you use the DHT to find 8 nodes and ask them to store the value. If they agree, they will connect to your node and download the tree and announce it as available for download, keeping it for the specified TTL.

```bash
# Push a tree onto the cluster 
$ crisscross push *clusters/my_cluster.yaml#Name 2UPe9oukYYpPvjGthmyazd1CtTQwddc1DNRxWykdxaXuE6M
True
```

This enables several interesting usecases:

* Collaborative Caching - Everybody has the key and accepts other peoples data
* PubSub like Distribution - One person has the key, with a group of peers following for updates and redistributing
* Private Hosting - Agree with nodes for them to host your data, encrypt it and send it to them with an infinite TTL

Any data that has a TTL larger than your MaxTTL of the cluster will be rejected so its important for the cluster to agree beforehand. 

You can disable this feature by destroying the PrivateKey after generating the cluster configuration.

## SQL Engine

From Python or Redis you can access the SQL engine to run complex SQL queries on immutable trees. Currently its rather limited (no ALTER TABLE staments and no INDEX support). Those things are supported by the engine ([GlueSQL](https://github.com/gluesql/gluesql)) however are not currently connected to the storage layer and need to be hooked up.

For more usage see the [Python client example](https://github.com/SoCal-Software-Labs/CrissCross/wiki/Python-Client#sql)

# Speed

For small values, CrissCross can be about 10-500x faster than inserting and announcing to IPFS over HTTP. For large values, the primary speed consideration (besides disk speed) is hashing. CrissCross uses Blake2, however switching to a non-cryptographic hash (like xxH3) increases the performance of inserting 10mb chunks by about 2-5x.

In the future there may be an option for a non-cryptographic CrissCross with embedded storage for maximum performance.

# Further Reading

* [Getting Started](https://github.com/SoCal-Software-Labs/CrissCross/wiki/Getting-Started)
* [Understanding TTLs](https://github.com/SoCal-Software-Labs/CrissCross/wiki/Understanding-TTLs)
* [Compaction](https://github.com/SoCal-Software-Labs/CrissCross/wiki/Compaction)
* [Using Redis](https://github.com/SoCal-Software-Labs/CrissCross/wiki/Redis-Example)
* [Redis API](https://github.com/SoCal-Software-Labs/CrissCross/wiki/Redis-API)
* [Using Python](https://github.com/SoCal-Software-Labs/CrissCross/wiki/Python-Client)
