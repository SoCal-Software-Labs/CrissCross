# CrissCross - Like IPFS... but with Redis Protocol, a SQL Layer, privacy and distribution as well as files

CrissCross is a new way to share immutable structures. Build a tree, get a hash and distribute it in your own private cluster. Connect with any language that has a redis client.

## Status

This is alpha software. Expect bugs and API changes.

## Why?

IPFS was built for files and the Web. Its API is HTTP, its abstraction is files. This datamodel is not quite right for building applications and sharing state. It is painfully slow to access from other languages and it is complex to access the underlying DAG to get raw block access.

In applications you need to manipulate *data* not files. Trees of integers, lists, maps, strings and tuples. Thus CrissCross was born. CrissCross is like IPFS, you get immutable data from a hash via P2P. However with CrissCross you talk to your node with the Redis Protocol for maximum performance and you insert polymorphic data in a btree instead of uploading files.

One of the primary design considerations of CrissCross is updating data. You can add a file to a folder, or insert an item into a btree and get a new hash. However if the person downloading the hash has the old tree, they only have to download the new nodes and dont have to iterate over the whole tree. Updates on terabyte sized databases become fast and easy.

Another important consideration is that CrissCross is private. IPFS on the otherhand is a public network where everyone is on the same DHT. CrissCross consists of private clusters. There is one shared overlay network that bootstraps you into your cluster. Inside your cluster the data stays private and encrypted over the wire. You can even supply your own overlay cluster and bootstrap nodes for maximum privacy.

## Features

* Immutable Key Value Trees, SQL Engine and File System
* Private Clusters - Setup a cluster of nodes to securely share files between them
* Broadcast data to the network preemptively
* Configurable Maximum TTL for each cluster - Store data for as long as you need
* Built with Redis and Elixir for maximum performance and reliability
* Simple clear protocol - Access from any language that has a Redis client
* Fast downloads with multiple connections
* Remotely access trees on other peoples machines to clone or query
* IPNS-like mutable pointers
* Over the wire encryption per cluster

## Example

With CrissCross, you insert values into a hash and get a new hash back. To start a new tree, insert into an empty hash:

#### Bash

```bash 
$ MYVAR=$(crisscross put "" "hello" "world")
# In the bash you get the Base58 Representation
$ echo $MYVAR
E555NKZfKRoUc5F62desomHFaQRz6tinAmehCbymudhv
$ crisscross get $MYVAR "hello"
world
```

#### Python

You can access the tree programmatically with Python (or any Redis client):

```python 
>>> client = CrissCross()
>>> location = client.put_multi("", [("hello", "world")])
# In the python client you manipulate the raw hash bytes, not the Base58 Representation
>>> location
b"\xc22\xdcz'\x8c\xa0\xc9}Y;\xbe\x1bD4<G6@?\x95\xc1k\x05{\x18\xc4\xc9\xbb\xba\xa65"
>>> base58.b58encode(location)
b'E555NKZfKRoUc5F62desomHFaQRz6tinAmehCbymudhv'
>>> client.get_multi(location, ["hello"])
b"world"
``````
With python you can store arbitrary data... tuples, lists, dictionaries, booleans, integers, floats and atoms. Not just binary text:

```python 
>>> location = client.put_multi("", [(("wow", 1.2), {1: (True, None)})])
>>> client.get_multi(location, [("wow", 1.2)])
{1: (True, None)}
``````

### Updates

Update a tree by referencing the hash of its previous state:

#### Python

```python 
>> new_location = client.put_multi(location, [("cool", 12345)])
b"HfTbW1XjXdT8RbQ7CMJnD2P73RHe3PJvSiPAFNj6Zzhp"
>> client.get(new_location, "cool")
12345
``````

#### Bash

```bash 
$ crisscross put $MYVAR "hello2" "world2"
47ZGfGj7V3M4HLUirhWWXD7sxD2sciro5YwSBnLinXXp
```

### Clone and Share Trees

Once you have a hash, you can share it on the network and others can clone it from you:

```bash
# On one machine
$ crisscross announce *defaultcluster 47ZGfGj7V3M4HLUirhWWXD7sxD2sciro5YwSBnLinXXp
47ZGfGj7V3M4HLUirhWWXD7sxD2sciro5YwSBnLinXXp
```

```bash
# On other machine query the tree without fully downloading it
$ crisscross remote_get *defaultcluster 47ZGfGj7V3M4HLUirhWWXD7sxD2sciro5YwSBnLinXXp "hello2"
"world2"
# They can clone the tree to get a local copy
$ crisscross remote_clone *defaultcluster 47ZGfGj7V3M4HLUirhWWXD7sxD2sciro5YwSBnLinXXp
True
$ crisscross get 47ZGfGj7V3M4HLUirhWWXD7sxD2sciro5YwSBnLinXXp "hello"
"world"
```
### SQL Engine

From Python or Redis you can access the SQL engine. Currently its rather limited (no ALTER TABLE staments and no INDEX support). Those things are supported by the engine ([GlueSQL](https://github.com/gluesql/gluesql)) however are not currently connected to the storage layer and need to be hooked up.


```python
>> client = CrissCross()
>>> location, ret = client.sql("", "CREATE TABLE MyCrissCrossTable (id INTEGER);")
>>> print(ret) # Get the result of the execution
[(Atom(b'ok'), b'Create')]
>>> location2, _ = client.sql(location, "INSERT INTO MyCrissCrossTable VALUES (100);")
>>> location3, _ = client.sql(location2, "INSERT INTO MyCrissCrossTable VALUES (200);")
>>> loc, ret = client.sql(location3, "SELECT * FROM MyCrissCrossTable WHERE id > 100;")
>>> print(ret[0][1])
{b'Select': {b'labels': [b'id'], b'rows': [[{b'I64': 200}]]}}
```
Or execute many statements at once:

```python
>>> location, sqlreturns = client.sql("", "CREATE TABLE MyCrissCrossTable (id INTEGER);", "INSERT INTO MyCrissCrossTable VALUES (100);", "INSERT INTO MyCrissCrossTable VALUES (200);", "SELECT * FROM MyCrissCrossTable WHERE id > 100;")
>>> print(sqlreturns)
[(Atom(b'ok'), b'Create'), (Atom(b'ok'), {b'Insert': 1}), (Atom(b'ok'), {b'Insert': 1}), (Atom(b'ok'), {b'Select': {b'labels': [b'id'], b'rows': [[{b'I64': 200}]]}})]
```

## Limitations

Right now there is no garbage collection for the data that is stored in CrissCross. When you delete data from a tree, the data still exists as the old hash is still valid. Theoretically you can solve this by removing all data that is not associated with a hash that you are currently broadcasting however is not implemented yet.

