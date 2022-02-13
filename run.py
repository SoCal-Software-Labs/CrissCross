import redis
import erlang  # erlang_py
import os
import sys
from pathlib import Path
import argparse
import base58
import yaml

DEFAULT_TTL = 1000 * 60 * 60 * 24


def decode(raw):
    return erlang.binary_to_term(raw)


def encode(raw):
    return erlang.term_to_binary(raw)


def read_var(t):
    if not t:
        return ""
    if t == "*defaultcluster":
        return base58.b58decode("8ZEftKHKUhq1hfxvx7HPxjZKffDhPku12Ck1nhczysxQ")
    elif t.startswith("*"):
        parts = t.split("#")
        base = parts[0].lstrip("*")
        with open(f"{base}", "r") as file:
            configuration = yaml.safe_load(file)
        return base58.b58decode(configuration[parts[1]])
    else:
        return base58.b58decode(t)


def print_get(m):
    if m:
        sys.stdout.buffer.write(next(iter(m.values())))


def print_ret(ret):
    if ret:
        print(base58.b58encode(ret).decode("utf8"))


class CrissCross:
    def __init__(self, host="localhost", port=11111, **kwargs):
        self.conn = redis.Redis(host=host, port=port, **kwargs)

    def keypair(self):
        ret = self.conn.execute_command("KEYPAIR")
        return ret[0], ret[1], ret[2]

    def cluster(self):
        ret = self.conn.execute_command("CLUSTER")
        return ret[0], ret[1], ret[2], ret[3]

    def push(self, cluster, value, ttl=DEFAULT_TTL):
        return self.conn.execute_command("PUSH", cluster, value, ttl) == b'OK'

    def remote(self, cluster, num_conns, *args):
        return self.conn.execute_command("REMOTE", cluster, num_conns, *args)

    def remote_no_local(self, cluster, num_conns, *args):
        return self.conn.execute_command("REMOTENOLOCAL", cluster, num_conns, *args)

    def var_set(self, var, val):
        return self.conn.execute_command("VARSET", var, val)

    def var_get(self, var):
        return self.conn.execute_command("VARGET", var, val)

    def var_with(self, var, *args):
        return self.conn.execute_command("VARWITH", var, *args)

    def bytes_written(self, tree):
        return self.conn.execute_command("BYTESWRITTEN", tree)

    def with_var_bytes_written(self, var):
        return self.conn.execute_command("WITHVAR", var, "BYTESWRITTEN")

    def remote_bytes_written(self, cluster, tree, num=1, cache=True):
        s = "REMOTE" if cache else "REMOTENOLOCAL"
        return self.conn.execute_command(
            s, cluster, num, "BYTESWRITTEN", tree, num=1, cache=True
        )

    def with_var_remote_bytes_written(self, var, cluster, num=1, cache=True):
        s = "REMOTE" if cache else "REMOTENOLOCAL"
        return self.conn.execute_command(
            "WITHVAR", var, s, cluster, num, "BYTESWRITTEN"
        )

    def put_multi(self, loc, kvs):
        flat_ls = [encode(item) for tup in kvs for item in tup]
        return self.conn.execute_command("PUTMULTI", loc, *flat_ls)

    def put_multi_bin(self, loc, kvs):
        flat_ls = [item for tup in kvs for item in tup]
        return self.conn.execute_command("PUTMULTIBIN", loc, *flat_ls)

    def delete_multi(self, loc, keys):
        keys = [encode(item) for item in keys]
        return self.conn.execute_command("DELMULTI", loc, *keys)

    def delete_multi_bin(self, loc, keys):
        return self.conn.execute_command("DELMULTIBIN", loc, *keys)

    def get_multi(self, loc, keys):
        keys = [encode(item) for item in keys]
        r = self.conn.execute_command("GETMULTI", loc, *keys)
        r = [decode(z) for z in r]
        return dict(zip(*[iter(r)] * 2))

    def get_multi_bin(self, loc, keys):
        r = self.conn.execute_command("GETMULTIBIN", loc, *keys)
        return dict(zip(*[iter(r)] * 2))

    def fetch(self, loc, key):
        key = encode(key)
        r = self.conn.execute_command("FETCH", loc, key)
        return decode(r)

    def fetch_bin(self, loc, key):
        return self.conn.execute_command("FETCHBIN", loc, key)

    def has_key(self, loc, key):
        key = encode(key)
        return self.conn.execute_command("HASKEY", loc, key) == 1

    def has_key_bin(self, loc, key):
        return self.conn.execute_command("HASKEYBIN", loc, key) == 1

    def sql(self, loc, *statements):
        r = self.conn.execute_command("SQL", loc, *statements)
        return r[0], [decode(s) for s in r[1:]]

    def remote_get_multi(self, cluster, loc, keys, num=1, cache=True):
        keys = [encode(item) for item in keys]
        s = "REMOTE" if cache else "REMOTENOLOCAL"
        r = self.conn.execute_command(s, cluster, num, "GETMULTI", loc, *keys)
        r = [decode(z) for z in r]
        return dict(zip(*[iter(r)] * 2))

    def remote_get_multi_bin(self, cluster, loc, keys, num=1, cache=True):
        s = "REMOTE" if cache else "REMOTENOLOCAL"
        r = self.conn.execute_command(s, cluster, num, "GETMULTIBIN", loc, *keys)
        return dict(zip(*[iter(r)] * 2))

    def remote_fetch(self, cluster, loc, key, num=1, cache=True):
        key = encode(key)
        s = "REMOTE" if cache else "REMOTENOLOCAL"
        r = self.conn.execute_command(s, cluster, num, "FETCH", loc, key)
        return decode(r)

    def remote_fetch_bin(self, cluster, loc, key, num=1, cache=True):
        s = "REMOTE" if cache else "REMOTENOLOCAL"
        return self.conn.execute_command(s, cluster, num, "FETCHBIN", loc, key)

    def remote_has_key(self, cluster, loc, key, num=1, cache=True):
        key = encode(key)
        s = "REMOTE" if cache else "REMOTENOLOCAL"
        return self.conn.execute_command(s, cluster, num, "HASKEY", loc, key) == 1

    def remote_has_key_bin(self, cluster, loc, key, num=1, cache=True):
        s = "REMOTE" if cache else "REMOTENOLOCAL"
        return self.conn.execute_command(s, cluster, num, "HASKEYBIN", loc, key) == 1

    def remote_sql(self, cluster, loc, *statements, num=1, cache=True):
        s = "REMOTE" if cache else "REMOTENOLOCAL"
        r = self.conn.execute_command(s, cluster, num, "SQL", loc, *statements)
        return r[0], [decode(s) for s in r[1:]]

    def with_var_put_multi(self, var, kvs):
        flat_ls = [encode(item) for tup in kvs for item in tup]
        return self.conn.execute_command("VARWITH", var, "PUTMULTI", *flat_ls)

    def with_var_put_multi_bin(self, var, kvs):
        flat_ls = [item for tup in kvs for item in tup]
        return self.conn.execute_command("VARWITH", var, "PUTMULTIBIN", *flat_ls)

    def with_var_delete_multi(self, loc, keys):
        keys = [encode(item) for item in keys]
        return self.conn.execute_command("VARWITH", var, "DELMULTI", *keys)

    def with_var_delete_multi_bin(self, var, keys):
        return self.conn.execute_command("VARWITH", var, "DELMULTIBIN", *keys)

    def with_var_get_multi(self, var, keys):
        keys = [encode(item) for item in keys]
        r = self.conn.execute_command("VARWITH", var, "GETMULTI", *keys)
        r = [decode(z) for z in r]
        return dict(zip(*[iter(r)] * 2))

    def with_var_get_multi_bin(self, var, keys):
        r = self.conn.execute_command("VARWITH", var, "GETMULTIBIN", *keys)
        return dict(zip(*[iter(r)] * 2))

    def with_var_fetch(self, var, key):
        key = encode(key)
        r = self.conn.execute_command("VARWITH", var, "FETCH", key)
        return decode(r)

    def with_var_fetch_bin(self, var, key):
        return self.conn.execute_command("VARWITH", var, "FETCHBIN", key)

    def with_var_has_key(self, var, key):
        key = encode(key)
        return self.conn.execute_command("VARWITH", var, "HASKEY", key) == 1

    def with_var_has_key_bin(self, var, key):
        return self.conn.execute_command("VARWITH", var, "HASKEYBIN", key) == 1

    def with_var_sql(self, var, *statements):
        r = self.conn.execute_command("VARWITH", var, "SQL", *statements)
        return r[0], [decode(s) for s in r[1:]]

    def with_var_remote_get_multi(self, var, cluster, keys, num=1, cache=True):
        keys = [encode(item) for item in keys]
        s = "REMOTE" if cache else "REMOTENOLOCAL"
        r = self.conn.execute_command(
            "VARWITH", var, s, cluster, num, "GETMULTI", *keys
        )
        r = [decode(z) for z in r]
        return dict(zip(*[iter(r)] * 2))

    def with_var_remote_get_multi_bin(self, var, cluster, keys, num=1, cache=True):
        s = "REMOTE" if cache else "REMOTENOLOCAL"
        r = self.conn.execute_command(
            "VARWITH", var, s, cluster, num, "GETMULTIBIN", *keys
        )
        return dict(zip(*[iter(r)] * 2))

    def with_var_remote_fetch(self, var, cluster, key, num=1, cache=True):
        key = encode(key)
        s = "REMOTE" if cache else "REMOTENOLOCAL"
        r = self.conn.execute_command("VARWITH", var, s, cluster, num, "FETCH", key)
        return decode(r)

    def with_var_remote_fetch_bin(self, var, cluster, key, num=1, cache=True):
        s = "REMOTE" if cache else "REMOTENOLOCAL"
        return self.conn.execute_command(
            "VARWITH", var, s, cluster, num, "FETCHBIN", key
        )

    def with_var_remote_has_key(self, var, cluster, key, num=1, cache=True):
        key = encode(key)
        s = "REMOTE" if cache else "REMOTENOLOCAL"
        return (
            self.conn.execute_command("VARWITH", var, s, cluster, num, "HASKEY", key)
            == 1
        )

    def with_var_remote_has_key_bin(self, var, cluster, key, num=1, cache=True):
        s = "REMOTE" if cache else "REMOTENOLOCAL"
        return (
            self.conn.execute_command("VARWITH", var, s, cluster, num, "HASKEYBIN", key)
            == 1
        )

    def with_var_remote_sql(self, var, cluster, *statements, num=1, cache=True):
        s = "REMOTE" if cache else "REMOTENOLOCAL"
        r = self.conn.execute_command(
            "VARWITH", var, s, cluster, num, "SQL", *statements
        )
        return r[0], [decode(s) for s in r[1:]]

    def announce(self, cluster, loc, ttl=DEFAULT_TTL):
        return self.conn.execute_command("ANNOUNCE", cluster, loc, str(ttl)) == b"OK"

    def has_announced(self, cluster, loc):
        return self.conn.execute_command("HASANNOUNCED", cluster, loc) == 1

    def pointer_set(self, cluster, private_key, val, ttl=DEFAULT_TTL):
        return self.conn.execute_command(
            "POINTERSET", cluster, private_key, val, str(ttl)
        )

    def pointer_lookup(self, cluster, name, generation=0):
        return self.conn.execute_command(
            "POINTERLOOKUP", cluster, name, str(generation)
        )

    def iter_start(self, loc):
        ret = self.conn.execute_command("ITERSTART", loc) == b"OK"
        if ret:
            while True:
                s = r.iter_next()
                if s is None:
                    break
                else:
                    yield s

    def with_var_iter_start(self, var):
        ret = self.conn.execute_command("WITHVAR", var, "ITERSTART") == b"OK"
        if ret:
            while True:
                s = r.iter_next()
                if s is None:
                    break
                else:
                    yield s

    def remote_iter_start(self, cluster, loc, num=1, cache=True):
        s = "REMOTE" if cache else "REMOTENOLOCAL"
        ret = self.conn.execute_command(s, cluster, str(num), "ITERSTART", loc) == b"OK"
        if ret:
            while True:
                s = r.iter_next()
                if s is None:
                    break
                else:
                    yield s

    def with_var_remote_iter_start(self, var, cluster, num=1, cache=True):
        s = "REMOTE" if cache else "REMOTENOLOCAL"
        ret = (
            self.conn.execute_command("WITHVAR", var, s, cluster, str(num), "ITERSTART")
            == b"OK"
        )
        if ret:
            while True:
                s = r.iter_next()
                if s is None:
                    break
                else:
                    yield s

    def iter_next(self):
        ret = self.conn.execute_command("ITERNEXT")
        if ret == b"DONE":
            return None
        return decode(ret[0]), decode(ret[1])

    def iter_stop(self):
        return self.conn.execute_command("ITERSTOP") == b"OK"

    def iter_start_opts(
        self, loc, min_key=None, max_key=None, inc_min=True, inc_max=True, reverse=False
    ):
        mink, maxk, imin, imax = self._make_min_max(min_key, max_key, inc_min, inc_max)
        rev = "true" if reverse else "false"
        ret = (
            self.conn.execute_command("ITERSTART", loc, mink, maxk, imin, imax, rev)
            == b"OK"
        )
        if ret:
            while True:
                s = r.iter_next()
                if s is None:
                    break
                else:
                    yield s

    def with_var_iter_start_opts(
        self, var, min_key=None, max_key=None, inc_min=True, inc_max=True, reverse=False
    ):
        mink, maxk, imin, imax = self._make_min_max(min_key, max_key, inc_min, inc_max)
        rev = "true" if reverse else "false"
        ret = (
            self.conn.execute_command(
                "WITHVAR", var, "ITERSTART", mink, maxk, imin, imax, rev
            )
            == b"OK"
        )
        if ret:
            while True:
                s = r.iter_next()
                if s is None:
                    break
                else:
                    yield s

    def remote_iter_start_opts(
        self,
        cluster,
        loc,
        min_key=None,
        max_key=None,
        inc_min=True,
        inc_max=True,
        reverse=False,
        num=1,
        cache=True,
    ):
        mink, maxk, imin, imax = self._make_min_max(min_key, max_key, inc_min, inc_max)
        rev = "true" if reverse else "false"
        s = "REMOTE" if cache else "REMOTENOLOCAL"
        ret = (
            self.conn.execute_command(
                s, cluster, str(num), "ITERSTART", loc, mink, maxk, imin, imax, rev
            )
            == b"OK"
        )
        if ret:
            while True:
                s = r.iter_next()
                if s is None:
                    break
                else:
                    yield s

    def with_var_remote_iter_start_opts(
        self,
        var,
        cluster,
        min_key=None,
        max_key=None,
        inc_min=True,
        inc_max=True,
        reverse=False,
        num=1,
        cache=True,
    ):
        mink, maxk, imin, imax = self._make_min_max(min_key, max_key, inc_min, inc_max)
        rev = "true" if reverse else "false"
        s = "REMOTE" if cache else "REMOTENOLOCAL"
        ret = (
            self.conn.execute_command(
                "WITHVAR",
                var,
                s,
                cluster,
                str(num),
                "ITERSTART",
                mink,
                maxk,
                imin,
                imax,
                rev,
            )
            == b"OK"
        )
        if ret:
            while True:
                s = r.iter_next()
                if s is None:
                    break
                else:
                    yield s

    def _make_min_max(self, min_key, max_key, inc_min, inc_max):
        minkey = ""
        imin = ""
        maxkey = ""
        imax = ""
        if min_key is not None:
            minkey = encode(min_key)
            imin = "true" if inc_min else "false"

        if max_key is not None:
            maxkey = encode(min_key)
            imax = "true" if inc_max else "false"

        return minkey, maxkey, imin, imax

    def upload(self, file_obj, chunk_size=1024 * 1024):
        loc = ""
        ix = 0
        while chunk := file_obj.read(chunk_size):
            loc = r.put_multi(loc, [(ix, chunk)])
            ix += len(chunk)
        return loc

    def upload_dir(self, tree, d, chunk_size=1024 * 1024):
        files = []
        p = Path(d)
        for i in p.glob("**/*"):
            if i.is_file():
                with open(i, "rb") as f:
                    loc = self.upload(f, chunk_size)
                    files.append(
                        (str(i), (erlang.Atom(b"embedded_tree"), loc, None))
                    )
        return r.put_multi(tree, files)

    def download(self, tree, file_obj):
        it = self.iter_start_opts(tree, min_key=0)
        self._do_download(file_obj, it)

    def download_dir(self, tree, d):
        it = self.iter_start_opts(tree, min_key=0)
        files = self._dir_files(it)
        for fn, (_, loc, _) in files:
            it = self.iter_start_opts(loc, min_key=0)
            self._download_file_in_dir(d, fn, loc, it)

    def ls(self, tree):
        it = self.iter_start_opts(tree, min_key=0)
        return [k for k, _ in self._dir_files(it)]

    def with_var_download(self, var, file_obj):
        it = self.with_var_iter_start_opts(var, min_key=0)
        self._do_download(file_obj, it)

    def remote_download(self, cluster, loc, file_obj, num=1, cache=True):
        it = self.remote_iter_start_opts(cluster, loc, min_key=0, num=num, cahce=cache)
        self._do_download(file_obj, it)

    def with_var_remote_download(self, var, cluster, file_obj, num=1, cache=True):
        it = self.with_var_iter_start_opts(
            var, cluster, min_key=0, num=num, cahce=cache
        )
        self._do_download(file_obj, it)

    def with_var_download_dir(self, var, file_obj):
        it = self.with_var_iter_start_opts(var, min_key=0)
        files = self._dir_files(it)
        for fn, (_, loc, _) in files:
            it = self.iter_start_opts(loc, min_key=0)
            self._download_file_in_dir(d, fn, loc, it)

    def remote_download_dir(self, cluster, loc, dir, num=1, cache=True):
        it = self.remote_iter_start_opts(cluster, loc, min_key=0, num=num, cahce=cache)
        files = self._dir_files(it)
        for fn, (_, loc, _) in files:
            it = self.iter_start_opts(loc, min_key=0, num=num, cahce=cache)
            self._download_file_in_dir(d, fn, loc)

    def with_var_remote_download_dir(self, var, cluster, dir, num=1, cache=True):
        it = self.with_var_iter_start_opts(
            var, cluster, min_key=0, num=num, cahce=cache
        )
        files = self._dir_files(it)
        for fn, (_, loc, _) in files:
            it = self.iter_start_opts(loc, min_key=0, num=num, cahce=cache)
            self._download_file_in_dir(d, fn, it)

    def _dir_files(self, it):
        files = []
        for s in it:
            if isinstance(s[0], bytes):
                files.append((s[0], s[1]))
        return files

    def _do_download(self, file_obj, it):
        for s in it:
            if isinstance(s[0], int) and isinstance(s[1], bytes):
                file_obj.write(s[1])

    def _download_file_in_dir(self, d, fn, it):
        real_fn = os.path.join(d, fn.decode("utf8"))
        directory = os.path.dirname(real_fn)
        if not os.path.exists(directory):
            os.makedirs(directory)
        with open(real_fn, "wb") as f:
            self._do_download(f, it)
    
    def remote_clone(self, cluster, loc, num=1, cache=True):
        s = "REMOTE" if cache else "REMOTENOLOCAL"
        return (
            self.conn.execute_command(s, cluster, str(num), "CLONE", loc)
            == b"OK"
        )

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command")

    subparser = subparsers.add_parser("keypair")
    subparser = subparsers.add_parser("cluster")
    subparser = subparsers.add_parser("node_secret")

    subparser = subparsers.add_parser("download_dir")
    subparser.add_argument("tree")
    subparser.add_argument("dir")

    parser_upload = subparsers.add_parser("upload_dir")
    parser_upload.add_argument("--tree", default=None)
    parser_upload.add_argument("dir")

    parser_upload = subparsers.add_parser("upload")
    parser_upload.add_argument("file")

    subparser = subparsers.add_parser("download")
    subparser.add_argument("tree")
    subparser.add_argument("destination")

    subparser = subparsers.add_parser("cat")
    subparser.add_argument("tree")

    subparser = subparsers.add_parser("ls")
    subparser.add_argument("tree")

    subparser = subparsers.add_parser("push")
    subparser.add_argument("cluster")
    subparser.add_argument("value")
    subparser.add_argument("--ttl", type=int, default=DEFAULT_TTL)

    subparser = subparsers.add_parser("announce")
    subparser.add_argument("cluster")
    subparser.add_argument("tree")
    subparser.add_argument("--ttl", type=int, default=DEFAULT_TTL)

    subparser = subparsers.add_parser("pointer_set")
    subparser.add_argument("cluster")
    subparser.add_argument("private_key")
    subparser.add_argument("value")
    subparser.add_argument("--ttl", type=int, default=DEFAULT_TTL)

    subparser = subparsers.add_parser("pointer_lookup")
    subparser.add_argument("cluster")
    subparser.add_argument("name")
    subparser.add_argument("--generation", type=int, default=0)

    subparser = subparsers.add_parser("bytes_written")
    subparser.add_argument("tree")

    subparser = subparsers.add_parser("var_set")
    subparser.add_argument("cluster")
    subparser.add_argument("key")
    subparser.add_argument("value")

    subparser = subparsers.add_parser("var_get")
    subparser.add_argument("cluster")
    subparser.add_argument("key")


    subparser = subparsers.add_parser("put")
    subparser.add_argument("tree")
    subparser.add_argument("key")
    subparser.add_argument("value")

    subparser = subparsers.add_parser("delete")
    subparser.add_argument("tree")
    subparser.add_argument("key")

    subparser = subparsers.add_parser("has_key")
    subparser.add_argument("tree")
    subparser.add_argument("key")

    subparser = subparsers.add_parser("get")
    subparser.add_argument("tree")
    subparser.add_argument("key")

    subparser = subparsers.add_parser("remote_bytes_written")
    subparser.add_argument("cluster")
    subparser.add_argument("tree")
    subparser.add_argument("--num", type=int, default=1)
    subparser.add_argument("--cache", type=bool, default=True)


    subparser = subparsers.add_parser("remote_has_key")
    subparser.add_argument("cluster")
    subparser.add_argument("tree")
    subparser.add_argument("key")
    subparser.add_argument("--num", type=int, default=1)
    subparser.add_argument("--cache", type=bool, default=True)

    subparser = subparsers.add_parser("remote_get")
    subparser.add_argument("cluster")
    subparser.add_argument("tree")
    subparser.add_argument("key")
    subparser.add_argument("--num", type=int, default=1)
    subparser.add_argument("--cache", type=bool, default=True)

    subparser = subparsers.add_parser("with_var_bytes_written")
    subparser.add_argument("cluster")
    subparser.add_argument("var")

    subparser = subparsers.add_parser("with_var_put")
    subparser.add_argument("var")
    subparser.add_argument("key")
    subparser.add_argument("value")

    subparser = subparsers.add_parser("with_var_delete")
    subparser.add_argument("var")
    subparser.add_argument("key")

    subparser = subparsers.add_parser("with_var_get")
    subparser.add_argument("var")
    subparser.add_argument("key")

    subparser = subparsers.add_parser("with_var_has_key")
    subparser.add_argument("var")
    subparser.add_argument("key")

    subparser = subparsers.add_parser("with_var_remote_get")
    subparser.add_argument("cluster")
    subparser.add_argument("var")
    subparser.add_argument("key")
    subparser.add_argument("--num", type=int, default=1)
    subparser.add_argument("--cache", type=bool, default=True)

    subparser = subparsers.add_parser("with_var_remote_has_key")
    subparser.add_argument("cluster")
    subparser.add_argument("var")
    subparser.add_argument("key")
    subparser.add_argument("--num", type=int, default=1)
    subparser.add_argument("--cache", type=bool, default=True)

    subparser = subparsers.add_parser("with_var_remote_bytes_written")
    subparser.add_argument("cluster")
    subparser.add_argument("var")
    subparser.add_argument("--num", type=int, default=1)
    subparser.add_argument("--cache", type=bool, default=True)

    subparser = subparsers.add_parser("remote_clone")
    subparser.add_argument("cluster")
    subparser.add_argument("tree")
    subparser.add_argument("--num", type=int, default=1)
    subparser.add_argument("--cache", type=bool, default=True)

    args = parser.parse_args()
    host = os.getenv("HOST", "localhost")
    port = int(os.getenv("PORT", "35002"))
    username = os.getenv("USERNAME", None)
    password = os.getenv("PASSWORD", None)
    r = CrissCrossClient(host=host, port=port, username=username, password=password)

    if args.command == "upload_dir":
        ret = r.upload_dir(read_var(args.tree), args.dir)
        print_ret(ret)
    elif args.command == "download_dir":
        r.download_dir(read_var(args.tree), args.dir)
    elif args.command == "upload":
        with open(args.file, "rb") as f:
            ret = r.upload(f)
        print_ret(ret)
    elif args.command == "download":
        with open(args.destination, "wb") as f:
            r.download(read_var(args.tree), f)
    elif args.command == "cat":
        r.download(read_var(args.tree), sys.stdout.buffer)
    elif args.command == "ls":
        for f in r.ls(read_var(args.tree)):
            print(f.decode("utf8"))
    elif args.command == "announce":
        r.announce(read_var(args.cluster), read_var(args.tree), args.ttl)
    elif args.command == "has_announced":
        print(r.has_announced(read_var(args.cluster), read_var(args.tree)))
    elif args.command == "pointer_set":
        ret = r.pointer_set(
            read_var(args.cluster),
            read_var(args.private_key),
            read_var(args.value),
            args.ttl,
        )
        print_ret(ret)
    elif args.command == "pointer_lookup":
        ret = r.pointer_lookup(
            read_var(args.cluster), read_var(args.name), args.generation
        )
        print_ret(ret)
    elif args.command == "var_set":
        ret = r.var_set(read_var(args.cluster), args.key, read_var(args.value))
        print_ret(ret)
    elif args.command == "var_get":
        ret = r.var_get(read_var(args.cluster), read_var(args.key))
        print_ret(ret)
    elif args.command == "put":
        ret = r.put_multi_bin(read_var(args.tree), [(args.key, args.value)])
        print_ret(ret)
    elif args.command == "delete":
        ret = r.delete_multi_bin(read_var(args.tree), [args.key])
        print_ret(ret)
    elif args.command == "get":
        print_get(r.get_multi_bin(read_var(args.tree), [args.key]))
    elif args.command == "has_key":
        print(r.has_key_bin(read_var(args.tree), args.key))
    elif args.command == "remote_get":
        print_get(
            r.remote_get_multi_bin(
                read_var(args.cluster),
                read_var(args.tree),
                [args.key],
                num=args.num,
                cache=args.cache,
            )
        )
    elif args.command == "remote_has_key":
        print(
            r.remote_has_key_bin(
                read_var(args.cluster),
                read_var(args.tree),
                args.key,
                num=args.num,
                cache=args.cache,
            )
        )
    elif args.command == "with_var_put":
        r.with_var_put_bin(args.var, [(args.key, args.value)])
    elif args.command == "with_var_delete":
        r.with_var_delete_multi_bin(args.var, [args.key])
    elif args.command == "with_var_get":
        print_get(r.with_var_get_multi_bin(args.var, [args.key]))
    elif args.command == "with_var_has_key":
        print(r.with_var_has_key_bin(args.var, args.key))
    elif args.command == "with_var_remote_get":
        print_get(
            r.with_var_remote_get_multi_bin(
                args.var,
                read_var(args.cluster),
                [args.key],
                num=args.num,
                cache=args.cache,
            )
        )
    elif args.command == "with_var_remote_has_key":
        print(
            r.with_var_remote_has_key_bin(
                args.var, args.key, num=args.num, cache=args.cache
            )
        )

    elif args.command == "bytes_written":
        print(r.bytes_written(read_var(args.tree)))

    elif args.command == "with_var_bytes_written":
        print(r.with_var_bytes_written(read_var(args.var)))

    elif args.command == "remote_bytes_written":
        print(
            r.remote_bytes_written(
                read_var(args.cluster), args.tree, num=args.num, cache=args.cache
            )
        )
    elif args.command == "with_var_remote_bytes_written":
        print(
            r.with_var_remote_bytes_written(
                args.var, num=args.num, cache=args.cache
            )
        )

    elif args.command == "keypair":
        ret = r.keypair()
        print(f"Name:       {base58.b58encode(ret[0]).decode('utf8')}")
        print(f"PublicKey:  {base58.b58encode(ret[1]).decode('utf8')}")
        print(f"PrivateKey: {base58.b58encode(ret[2]).decode('utf8')}")
    elif args.command == "cluster":
        ret = r.cluster()
        print(f"Name:       {base58.b58encode(ret[0]).decode('utf8')}")
        print(f"Cypher:     {base58.b58encode(ret[1]).decode('utf8')}")
        print(f"PublicKey:  {base58.b58encode(ret[2]).decode('utf8')}")
        print(f"PrivateKey: {base58.b58encode(ret[3]).decode('utf8')}")
        print(f"MaxTTL:     {DEFAULT_TTL}")
    elif args.command == "node_secret":
        ret = r.keypair()
        print(base58.b58encode(ret[2]).decode("utf8"))
    elif args.command == "push":
        print(
            r.push(
                read_var(args.cluster),
                read_var(args.value),
                ttl=args.ttl,
            )
        )
    elif args.command == "remote_clone":
        print_get(
            r.remote_clone(
                read_var(args.cluster),
                read_var(args.tree),
                num=args.num,
                cache=args.cache,
            )
        )
    # cluster FqcdM9XXWs7dXMPxMNeVCEhSdFk46kAyrNxxeT8V81W7

    location = r.put_multi("", [(("wow", 1.2), {1: (True, None)})])
    print_ret(location)
    location = r.put_multi(location, [("cool", 12345)])
    print_ret(location)
    # print(loc)
    # print(r.get_multi_bin(loc, ["key"]))

    # loc = r.put_multi("", [("key", {True: (1, None)})])
    # print(loc)
    # print(r.get_multi(loc, ["key"]))
    # r.var_set("myvar", loc)
    # print(r.with_var_fetch("myvar", "key"))

    # loc = bytes(bytearray([212, 145, 143, 43, 142, 168, 217, 165, 212, 224, 187, 21, 73, 32, 88, 9, 165,  206, 229, 41, 156, 77, 141, 238, 210, 55, 204, 194, 167, 24, 8, 94]))
    # cluster = bytearray([176, 79, 169, 41, 223, 243, 145, 29, 121, 206, 82, 147, 249, 215, 95, 21, 3, 216, 230, 115, 108, 18, 254, 172, 108, 198, 233, 214, 217, 163, 217, 253])

    # print(r.remote_sql(bytes(cluster), loc, "SELECT * FROM Glue"))

    # print(r.remote_iter_start_opts(bytes(cluster), loc, min_key=b"ZZZ", inc_min=False))
    # while True:
    #     s = r.iter_next()
    #     if s is None:
    #         break
    #     else:
    #         print(s)

    # loc = r.upload_dir('', './native')
    # r.download_dir(loc, './native-new')

    # print(loc)
    # import io
    # myBytesIO = io.BytesIO()
    # r.download(loc, myBytesIO)
    # print(myBytesIO.getvalue())

    # print(r.iter_start_opts(loc, min_key=0, inc_min=True))
    # while True:
    #     s = r.iter_next()
    #     if s is None:
    #         break
    #     else:
    #         print(s)

    # with open("run.py", "rb") as f:
    #     print(f.read() == myBytesIO.getvalue())
