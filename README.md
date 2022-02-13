# CrissCross - Like IPFS... but for data structures, SQL, files, distribution and privacy.

CrissCross is a new way to share immutable structures. Build a tree, get a hash and distribute it in your own private cluster. Connect with any language that has a redis client.

## Why?

IPFS was built for files and the Web. Its API is HTTP, its interface is files. This datamodel is not quite right for building applications and sharing state. It is painfully slow to access from other languages and it is complex to access the underlying DAG to get raw block access.

In applications you need to manipulate *data* not files. Trees of integers, lists, maps, strings and tuples. Thus CrissCross was born. CrissCross is like IPFS... you get immutable data from a hash via P2P. However with CrissCross you talk to your client with the Redis Protocol for maximum performance and you insert polymorphic data in a btree instead of uploading files.

One of the primary design considerations of CrissCross is updating data. You can add a file to a folder, or insert an item into a btree and get a new hash. However if the person downloading the hash has the old tree, they only have to download the new nodes and dont have to iterate over the whole tree. Updates on terabyte sized databases become fast and easy.

Another important consideration is that CrissCross is private. IPFS on the otherhand is a public network where everyone is on the same DHT. CrissCross consists of private clusters. There is one shared overlay network that bootstraps you into your cluster. Inside your cluster the data stays private and encrypted over the wire. You can even supply your own overlay cluster and bootstrap nodes for maximum privacy.

## Features

* Immutable Key Value Trees, SQL Engine and File System
* Private Clusters - Setup a cluster of nodes to securely share files between them
* Broadcast data to the network preemptively
* Configurable Maximum TTL for each cluster - Store data for as long as you need
* Built with Redis and Erlang for maximum performance and reliability
* Simple clear protocol - Access from any language that has a Redis client
* Fast downloads with multiple connections
* Remotely access trees on other peoples machines to clone or query
* IPNS-like mutable pointers

## Example

With CrissCross, you insert values into a hash and get a new hash back. To start a new tree, insert into an empty hash:

#### Bash

```bash 
$ MYVAR=$(crisscross put "" "hello" "world")
$ echo $MYVAR
E555NKZfKRoUc5F62desomHFaQRz6tinAmehCbymudhv
$ crisscross get $MYVAR "hello"
world
```

#### Python

You can access the tree programmatically with Python (or any Redis client):

```python 
>> client = CrissCross()
>> location = client.put_multi("", [("hello", "world")])
b"E555NKZfKRoUc5F62desomHFaQRz6tinAmehCbymudhv"
>> client.get(location, "hello")
b"world"
``````
With python you can store arbitrary data... Not just text:

```python 
>> location = client.put_multi("", [(("wow", 1.2), {1: (True, None)})])
b"8fTKZtuVnrz9vAMvxBEs4VX1xAwiMhYWLK7h3E5FCbjG"
>> client.get(location, ("wow", 1.2))
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
$ crisscross get 47ZGfGj7V3M4HLUirhWWXD7sxD2sciro5YwSBnLinXXp "hello2"
"world2"
```
