// python: call Python from Volt. start() embeds the interpreter, which shuts down when the value it
// returns is deleted. An object holds one Python object: copying it adds a reference, deleting it
// drops one. Volt values convert to Python ones on the way in (value(x), and every argument of
// call) and back with to_i64, to_f64, to_bool and to_string. A Python exception comes back as
// python_error::EXCEPTION("Type: message"). The thread that started Python holds the GIL; another
// thread takes it with gil() while the first lets go of it in without_gil(...).
use { "Python.h" } as c;

public error python_error {
    EXCEPTION: std::string,
}

// ---------- the interpreter ----------

public struct interpreter {
    owner: bool = false; // this one started Python, so deleting it stops Python
}

// starts Python (already running: a handle that leaves it running)
public fn start() -> interpreter {
    if (c::Py_IsInitialized() != 0) {
        return { owner: false };
    }
    c::Py_InitializeEx(0); // 0: leave the program's signal handlers alone
    return { owner: true };
}

public attach fn delete(this: interpreter&) -> void {
    if (this.owner) {
        c::Py_FinalizeEx();
        this.owner = false;
    }
}

// runs f with the GIL let go, so other threads can take it (python::gil()); this thread must hold it
<F: type>
public attach fn without_gil(this: interpreter&, f: F) -> void {
    val saved = c::PyEval_SaveThread();
    f();
    c::PyEval_RestoreThread(saved);
}

// the GIL, held until this is deleted: what a thread other than the starting one needs around its
// Python calls
public struct gil_guard {
    state: i32 = 0;
}

public fn gil() -> gil_guard {
    return { state: c::PyGILState_Ensure() };
}

public attach fn delete(this: gil_guard&) -> void {
    c::PyGILState_Release(this.state);
}

// ---------- objects ----------

public struct object {
    ptr: c::PyObject* = null;
}

public attach fn delete(this: object&) -> void {
    if (this.ptr != null) {
        c::Py_DecRef(this.ptr);
        this.ptr = null;
    }
}

public attach fn copy(this: object&) -> object {
    if (this.ptr != null) {
        c::Py_IncRef(this.ptr);
    }
    return { ptr: this.ptr };
}

// text of a Python str ("" when it isn't one)
public fn text(p: c::PyObject*) -> std::string {
    var n: isize = 0;
    val got = c::PyUnicode_AsUTF8AndSize(p, &n);
    if (got == null) {
        c::PyErr_Clear();
    }
    val s = got ?? return std::string::from("");
    return std::string::from(@cast<str>(@slice(@cast<u8*>(s), @cast<usize>(n))));
}

// the pending Python exception as an error, "Type: message" (and clears it)
public fn fetch() -> python_error {
    var t: c::PyObject* = null;
    var v: c::PyObject* = null;
    var tb: c::PyObject* = null;
    c::PyErr_Fetch(&t, &v, &tb);
    c::PyErr_NormalizeException(&t, &v, &tb);
    var msg = std::string::from("");
    if (t != null) {
        val name = c::PyObject_GetAttrString(t, "__name__");
        if (name != null) {
            msg.append(text(name).as_str());
            c::Py_DecRef(name);
        }
    }
    if (v != null) {
        val s = c::PyObject_Str(v);
        if (s != null) {
            val m = text(s);
            if (m.len() > 0) {
                msg.append(": ");
                msg.append(m.as_str());
            }
            c::Py_DecRef(s);
        }
    }
    val refs: c::PyObject*[3] = { t, v, tb };
    for (r) in refs {
        if (r != null) {
            c::Py_DecRef(r);
        }
    }
    c::PyErr_Clear();
    return python_error::EXCEPTION(move msg);
}

// a new reference as an object; null: the exception that made it
public fn own(p: c::PyObject*) -> python_error!object {
    if (p == null) {
        return fetch();
    }
    return { ptr: p };
}

// x as a Python object: integers, floats, bool, str, std::string, and objects (as they are)
<T: type>
public fn value(x: T) -> python_error!object {
    @compile_error("python::value takes integers, f64, f32, bool, str, std::string and python::object");
}
public fn value<i64>(x: i64) -> python_error!object { return own(c::PyLong_FromLongLong(x)); }
public fn value<i32>(x: i32) -> python_error!object { return own(c::PyLong_FromLongLong(x as i64)); }
public fn value<u64>(x: u64) -> python_error!object { return own(c::PyLong_FromUnsignedLongLong(x)); }
public fn value<usize>(x: usize) -> python_error!object { return own(c::PyLong_FromUnsignedLongLong(x as u64)); }
public fn value<f64>(x: f64) -> python_error!object { return own(c::PyFloat_FromDouble(x)); }
public fn value<f32>(x: f32) -> python_error!object { return own(c::PyFloat_FromDouble(x as f64)); }
public fn value<bool>(x: bool) -> python_error!object {
    var n: i64 = 0;
    if (x) {
        n = 1;
    }
    return own(c::PyBool_FromLong(n));
}
public fn value<str>(x: str) -> python_error!object { return own(c::PyUnicode_FromStringAndSize(@cast<cstr>(x.ptr), @cast<isize>(x.len))); }
public fn value<std::string>(x: std::string) -> python_error!object { return value(x.as_str()); }
public fn value<object>(x: object) -> python_error!object { return x; }

// None
public fn none() -> python_error!object {
    return eval("None");
}

// the module called name (import name)
public fn import(name: str) -> python_error!object {
    var n = std::string::from(name);
    return own(c::PyImport_ImportModule(n.c_str()));
}

// __main__'s namespace, where eval and exec run (borrowed)
public fn main_dict() -> c::PyObject* {
    return c::PyModule_GetDict(c::PyImport_AddModule("__main__"));
}

// the value of a Python expression
public fn eval(expr: str) -> python_error!object {
    var code = std::string::from(expr);
    val d = main_dict();
    return own(c::PyRun_StringFlags(code.c_str(), c::Py_eval_input, d, d, null));
}

// runs Python statements in __main__ (what they define stays there for eval)
public fn exec(code: str) -> python_error!void {
    var text = std::string::from(code);
    val d = main_dict();
    val r = try own(c::PyRun_StringFlags(text.c_str(), c::Py_file_input, d, d, null));
}

// this.name
public attach fn get(this: object&, name: str) -> python_error!object {
    var n = std::string::from(name);
    return own(c::PyObject_GetAttrString(this.ptr, n.c_str()));
}

// a tuple of the list's items, then f(*tuple)
public fn call_list(f: c::PyObject*, list: object&) -> python_error!object {
    val args = try own(c::PyList_AsTuple(list.ptr));
    return own(c::PyObject_CallObject(f, args.ptr));
}

// this(args...), each argument converted with value
<Args: type...>
public attach fn call(this: object&, args: Args...) -> python_error!object {
    var list = try own(c::PyList_New(0));
    comptime for (a) in args {
        val item = try value(copy a); // an element can't be moved out of (an object: a new reference)
        if (c::PyList_Append(list.ptr, item.ptr) != 0) {
            return fetch();
        }
    }
    return call_list(this.ptr, &list);
}

// this.name(args...)
<Args: type...>
public attach fn call_method(this: object&, name: str, args: Args...) -> python_error!object {
    val f = try this.get(name);
    var list = try own(c::PyList_New(0));
    comptime for (a) in args {
        val item = try value(copy a); // an element can't be moved out of (an object: a new reference)
        if (c::PyList_Append(list.ptr, item.ptr) != 0) {
            return fetch();
        }
    }
    return call_list(f.ptr, &list);
}

// this[key]
<K: type>
public attach fn item(this: object&, key: K) -> python_error!object {
    val k = try value(key);
    return own(c::PyObject_GetItem(this.ptr, k.ptr));
}

public attach fn is_none(this: object&) -> bool {
    return c::Py_IsNone(this.ptr) != 0;
}

public attach fn to_i64(this: object&) -> python_error!i64 {
    val v = c::PyLong_AsLongLong(this.ptr);
    if (v == -1 && c::PyErr_Occurred() != null) {
        return fetch();
    }
    return v;
}

public attach fn to_f64(this: object&) -> python_error!f64 {
    val v = c::PyFloat_AsDouble(this.ptr);
    if (v == -1.0 && c::PyErr_Occurred() != null) {
        return fetch();
    }
    return v;
}

public attach fn to_bool(this: object&) -> python_error!bool {
    val v = c::PyObject_IsTrue(this.ptr);
    if (v < 0) {
        return fetch();
    }
    return v == 1;
}

// str(this)
public attach fn to_string(this: object&) -> python_error!std::string {
    val s = try own(c::PyObject_Str(this.ptr));
    return text(s.ptr);
}

// repr(this)
public attach fn repr(this: object&) -> python_error!std::string {
    val s = try own(c::PyObject_Repr(this.ptr));
    return text(s.ptr);
}
