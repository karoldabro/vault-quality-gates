"""The stub tool of tests/unit/qg-sandbox.bats: tries one forbidden act and prints what happened.

usage: python3 -I qg-sandbox-probe.py <act> [<arg>...]
  write <path>...   appends to each path; prints "ok <path>" or "denied <path>"
  unix              socket(AF_UNIX); prints "unix ok" or "unix errno <n>"
  unixhigh          raw socket() with AF_UNIX in the low 32 bits and high bits set
  inet              AF_INET, AF_INET6 and socketpair(AF_UNIX); one line each
  fds <n>...        prints "open <n>" or "closed <n>" per descriptor
  kill <pid>        sends SIGTERM; prints "kill ok" or "kill errno <n>"
  nr <number>       a raw system call with no arguments; prints "nr errno <n>" or "nr ok"
  int80             socketcall(SYS_SOCKET, AF_UNIX) through the 32-bit int 0x80 entry (x86_64 only)
"""
import ctypes
import os
import platform
import socket
import sys

libc = ctypes.CDLL(None, use_errno=True)
libc.syscall.restype = ctypes.c_long
NR_SOCKET = {"x86_64": 41, "aarch64": 198}[platform.machine()]


def raw(nr, *args):
    rc = libc.syscall(ctypes.c_long(nr), *[ctypes.c_long(a) for a in args])
    return rc, ctypes.get_errno()


def main(act, args):
    if act == "write":
        for p in args:
            try:
                with open(p, "a") as f:
                    f.write("x\n")
                print(f"ok {p}")
            except OSError:
                print(f"denied {p}")
    elif act == "unix":
        try:
            socket.socket(socket.AF_UNIX, socket.SOCK_STREAM).close()
            print("unix ok")
        except OSError as e:
            print(f"unix errno {e.errno}")
    elif act == "unixhigh":
        rc, err = raw(NR_SOCKET, 0x100000001, socket.SOCK_STREAM, 0)
        print("unixhigh ok" if rc >= 0 else f"unixhigh errno {err}")
    elif act == "inet":
        for name, fam in (("inet", socket.AF_INET), ("inet6", socket.AF_INET6)):
            try:
                socket.socket(fam, socket.SOCK_STREAM).close()
                print(f"{name} ok")
            except OSError as e:
                print(f"{name} errno {e.errno}")
        try:
            a, b = socket.socketpair(socket.AF_UNIX)
            a.close()
            b.close()
            print("socketpair ok")
        except OSError as e:
            print(f"socketpair errno {e.errno}")
    elif act == "rename":
        # As pub precompiles: write in a temporary subfolder, then move the file up one folder.
        d = args[0]
        try:
            os.makedirs(f"{d}/tmp", exist_ok=True)
            with open(f"{d}/tmp/f", "w") as f:
                f.write("x")
            os.rename(f"{d}/tmp/f", f"{d}/f")
            os.link(f"{d}/f", f"{d}/tmp/g")
            print("rename ok")
        except OSError as e:
            print(f"rename errno {e.errno}")
    elif act == "dgrampair":
        for name, kind in (("dgram", socket.SOCK_DGRAM), ("seqpacket", socket.SOCK_SEQPACKET),
                           ("stream-cloexec", socket.SOCK_STREAM | socket.SOCK_CLOEXEC | socket.SOCK_NONBLOCK)):
            try:
                a, b = socket.socketpair(socket.AF_UNIX, kind)
                a.close()
                b.close()
                print(f"{name} ok")
            except OSError as e:
                print(f"{name} errno {e.errno}")
    elif act == "owner":
        p = args[0]
        for name, call in (("chown", lambda: os.chown(p, os.getuid(), os.getgid())),
                           ("lchown", lambda: os.lchown(p, os.getuid(), os.getgid())),
                           ("setxattr", lambda: os.setxattr(p, "user.qg", b"x")),
                           ("removexattr", lambda: os.removexattr(p, "user.qg")),
                           ("chmod", lambda: os.chmod(p, 0o644)),
                           ("utime", lambda: os.utime(p))):
            try:
                call()
                print(f"{name} ok")
            except OSError as e:
                print(f"{name} errno {e.errno}")
    elif act == "escape":
        # A grandchild that starts its own session and outlives this process.
        if os.fork() == 0:
            os.setsid()
            if os.fork() == 0:
                with open(args[0], "w") as f:
                    f.write(str(os.getpid()))
                os.execvp("sleep", ["sleep", "300"])
            os._exit(0)
        os.wait()
        import time
        for _ in range(50):
            if os.path.exists(args[0]) and os.path.getsize(args[0]):
                break
            time.sleep(0.05)
        print("escape started")
    elif act == "fds":
        for n in args:
            try:
                os.fstat(int(n))
                print(f"open {n}")
            except OSError:
                print(f"closed {n}")
    elif act == "kill":
        try:
            os.kill(int(args[0]), 15)
            print("kill ok")
        except OSError as e:
            print(f"kill errno {e.errno}")
    elif act == "nr":
        rc, err = raw(int(args[0], 0))
        print("nr ok" if rc >= 0 else f"nr errno {err}")
    elif act == "int80":
        libc.mmap.restype = ctypes.c_void_p
        libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_long]
        # PROT_READ|WRITE|EXEC; MAP_PRIVATE|MAP_ANONYMOUS|MAP_32BIT, so int 0x80 can reach the arguments.
        mem = libc.mmap(None, 4096, 7, 0x02 | 0x20 | 0x40, -1, 0)
        args_at = mem + 0x100
        ctypes.memmove(args_at, (ctypes.c_uint32 * 3)(1, 1, 0), 12)
        code = bytes([0x53, 0xB8, 102, 0, 0, 0, 0xBB, 1, 0, 0, 0, 0xB9]) + args_at.to_bytes(4, "little") \
            + bytes([0xCD, 0x80, 0x5B, 0xC3])
        ctypes.memmove(mem, code, len(code))
        print("int80 calling", flush=True)
        rc = ctypes.CFUNCTYPE(ctypes.c_int)(mem)()
        print(f"int80 returned {rc}", flush=True)


main(sys.argv[1], sys.argv[2:])
