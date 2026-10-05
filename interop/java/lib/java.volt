// java: call Java from Volt through JNI. start(classpath) starts a JVM in this process (a JVM
// starts once per process; it stops when the vm is deleted). find_class gives a class; methods are
// called by name and JNI signature ("(II)I", "(Ljava/lang/String;)Ljava/lang/String;") with Volt
// arguments, converted: integers, floats, bool, str (a new Java String) and objects. Objects are
// global references (copying one adds a reference, deleting it drops it). A Java exception comes
// back as java_error::THROWN with its toString(): "java.lang.ArithmeticException: / by zero".
use { "jni.h" } as jni;

public error java_error {
    THROWN: std::string,
}

// ---------- the JVM ----------

public struct vm {
    jvm: jni::JavaVM* = null;
    env: jni::JNIEnv* = null;
}

// starts the JVM with this class path (directories and jars, joined with ':')
public fn start(classpath: str) -> java_error!vm {
    var cp = std::string::from("-Djava.class.path=");
    cp.append(classpath);
    var opt: jni::JavaVMOption = { optionString: cp.c_str() };
    var args: jni::JavaVMInitArgs = { version: jni::JNI_VERSION_10, nOptions: 1, options: &opt, ignoreUnrecognized: 0 };
    var out: vm = {};
    var envp: void* = null;
    if (jni::JNI_CreateJavaVM(&out.jvm, &envp, &args) != jni::JNI_OK) {
        return java_error::THROWN(std::string::from("JNI_CreateJavaVM failed (is a JVM already running?)"));
    }
    out.env = @cast<jni::JNIEnv*>(envp);
    return out;
}

public attach fn delete(this: vm&) -> void {
    if (this.jvm != null) {
        val f = (*this.jvm)->DestroyJavaVM;
        if (f) {
            f(this.jvm);
        }
        this.jvm = null;
    }
}

// JNI's functions
public fn fns(env: jni::JNIEnv*) -> jni::JNINativeInterface_* {
    return @cast<jni::JNINativeInterface_*>(*env);
}

// ---------- objects ----------

// a global reference to a Java object: a class, a string, anything
public struct object {
    env: jni::JNIEnv* = null;
    ref: jni::jobject = null;
}

public attach fn delete(this: object&) -> void {
    if (this.ref != null) {
        (fns(this.env)->DeleteGlobalRef ?? return)(this.env, this.ref);
        this.ref = null;
    }
}

public attach fn copy(this: object&) -> object {
    if (this.ref == null) {
        return { env: this.env };
    }
    return { env: this.env, ref: (fns(this.env)->NewGlobalRef ?? @panic("JNI"))(this.env, this.ref) };
}

// a global reference for a local one (which is released); null: the pending exception
public fn global(env: jni::JNIEnv*, local: jni::jobject) -> java_error!object {
    try check(env);
    if (local == null) {
        return { env: env };
    }
    val t = fns(env);
    val g = (t->NewGlobalRef ?? @panic("JNI"))(env, local);
    (t->DeleteLocalRef ?? @panic("JNI"))(env, local);
    return { env: env, ref: g };
}

public attach fn is_null(this: object&) -> bool {
    return this.ref == null;
}

// ---------- exceptions ----------

// the pending Java exception as an error (and clears it)
public fn check(env: jni::JNIEnv*) -> java_error!void {
    val t = fns(env);
    if ((t->ExceptionCheck ?? @panic("JNI"))(env) == 0) {
        return;
    }
    val ex = (t->ExceptionOccurred ?? @panic("JNI"))(env);
    (t->ExceptionClear ?? @panic("JNI"))(env);
    val f = frame(env);   // releases ex and what reading it makes
    var msg = std::string::from("a Java exception");
    val cls = (t->GetObjectClass ?? @panic("JNI"))(env, ex);
    val mid = (t->GetMethodID ?? @panic("JNI"))(env, cls, "toString", "()Ljava/lang/String;");
    if (mid != null) {
        val s = (t->CallObjectMethodA ?? @panic("JNI"))(env, ex, mid, null);
        if (s != null && (t->ExceptionCheck ?? @panic("JNI"))(env) == 0) {
            msg = text(env, s);
        }
        (t->ExceptionClear ?? @panic("JNI"))(env);
    }
    return java_error::THROWN(move msg);
}

// a java.lang.String's text
public fn text(env: jni::JNIEnv*, s: jni::jobject) -> std::string {
    val t = fns(env);
    val chars = (t->GetStringUTFChars ?? @panic("JNI"))(env, s, null) ?? return std::string::from("");
    val n = (t->GetStringUTFLength ?? @panic("JNI"))(env, s);
    val out = std::string::from(@cast<str>(@slice(@cast<u8*>(chars), @cast<usize>(n))));
    (t->ReleaseStringUTFChars ?? @panic("JNI"))(env, s, chars);
    return out;
}

// ---------- classes, strings ----------

// the class called name: "java/lang/Math", "Calc", "com/example/Thing"
public attach fn find_class(this: vm&, name: str) -> java_error!object {
    var n = std::string::from(name);
    return global(this.env, (fns(this.env)->FindClass ?? @panic("JNI"))(this.env, n.c_str()));
}

// a new java.lang.String
public attach fn string(this: vm&, s: str) -> java_error!object {
    var n = std::string::from(s);
    return global(this.env, (fns(this.env)->NewStringUTF ?? @panic("JNI"))(this.env, n.c_str()));
}

// a Java String's text (String.valueOf for anything else, through toString)
public attach fn to_string(this: object&) -> java_error!std::string {
    if (this.ref == null) {
        return std::string::from("null");
    }
    val r = try this.call_object("toString", "()Ljava/lang/String;");
    return text(this.env, r.ref);
}

// ---------- arguments ----------

// a JNI local frame until this is deleted: the local references a call makes (its str arguments)
// go with it
public struct local_frame {
    env: jni::JNIEnv*;
}

public fn frame(env: jni::JNIEnv*) -> local_frame {
    (fns(env)->PushLocalFrame ?? @panic("JNI"))(env, 16);
    return { env: env };
}

public attach fn delete(this: local_frame&) -> void {
    (fns(this.env)->PopLocalFrame ?? @panic("JNI"))(this.env, null);
}

// x as a JNI argument; a str becomes a new String (a local reference, released after the call).
// x stays the caller's: an object argument is lent to the call (pass `copy o` to keep using o)
<T: type>
public fn jarg(env: jni::JNIEnv*, x: T&) -> jni::jvalue {
    @compile_error("java arguments are integers, f64, f32, bool, str and java::object");
}
public fn jarg<i32>(env: jni::JNIEnv*, x: i32&) -> jni::jvalue { var v: jni::jvalue = { i: *x }; return v; }
public fn jarg<i64>(env: jni::JNIEnv*, x: i64&) -> jni::jvalue { var v: jni::jvalue = { j: *x }; return v; }
public fn jarg<i16>(env: jni::JNIEnv*, x: i16&) -> jni::jvalue { var v: jni::jvalue = { s: *x }; return v; }
public fn jarg<i8>(env: jni::JNIEnv*, x: i8&) -> jni::jvalue { var v: jni::jvalue = { b: *x }; return v; }
public fn jarg<f64>(env: jni::JNIEnv*, x: f64&) -> jni::jvalue { var v: jni::jvalue = { d: *x }; return v; }
public fn jarg<f32>(env: jni::JNIEnv*, x: f32&) -> jni::jvalue { var v: jni::jvalue = { f: *x }; return v; }
public fn jarg<bool>(env: jni::JNIEnv*, x: bool&) -> jni::jvalue {
    var v: jni::jvalue = { z: 0 };
    if (*x) {
        v.z = 1;
    }
    return v;
}
public fn jarg<str>(env: jni::JNIEnv*, x: str&) -> jni::jvalue {
    var n = std::string::from(*x);
    var v: jni::jvalue = { l: (fns(env)->NewStringUTF ?? @panic("JNI"))(env, n.c_str()) };
    return v;
}
public fn jarg<object>(env: jni::JNIEnv*, x: object&) -> jni::jvalue { var v: jni::jvalue = { l: x.ref }; return v; }

// what a call returns, by the kind of method
public enum kind {
    VOID,
    INT,
    LONG,
    DOUBLE,
    BOOL,
    OBJECT,
}

// calls a static method (this is a class) or an instance method, with the arguments made, inside
// a local frame that frees their local references
public fn invoke(target: object&, is_static: bool, name: str, sig: str, args: jni::jvalue[..], k: kind) -> java_error!jni::jvalue {
    if (target.ref == null) {
        return java_error::THROWN(std::fmt::format("java.lang.NullPointerException: {} on null", name));
    }
    val env = target.env;
    val t = fns(env);
    var n = std::string::from(name);
    var s = std::string::from(sig);
    var cls = target.ref;
    if (!is_static) {
        cls = (t->GetObjectClass ?? @panic("JNI"))(env, target.ref);
    }
    var mid: jni::jmethodID = null;
    if (is_static) {
        mid = (t->GetStaticMethodID ?? @panic("JNI"))(env, cls, n.c_str(), s.c_str());
    } else {
        mid = (t->GetMethodID ?? @panic("JNI"))(env, cls, n.c_str(), s.c_str());
    }
    try check(env);
    var first: jni::jvalue* = null;
    if (args.len > 0) {
        first = &args[0];
    }
    var r: jni::jvalue = { j: 0 };
    match (k) {
        .VOID => {
            if (is_static) { (t->CallStaticVoidMethodA ?? @panic("JNI"))(env, cls, mid, first); } else { (t->CallVoidMethodA ?? @panic("JNI"))(env, target.ref, mid, first); }
        },
        .INT => {
            if (is_static) { r.i = (t->CallStaticIntMethodA ?? @panic("JNI"))(env, cls, mid, first); } else { r.i = (t->CallIntMethodA ?? @panic("JNI"))(env, target.ref, mid, first); }
        },
        .LONG => {
            if (is_static) { r.j = (t->CallStaticLongMethodA ?? @panic("JNI"))(env, cls, mid, first); } else { r.j = (t->CallLongMethodA ?? @panic("JNI"))(env, target.ref, mid, first); }
        },
        .DOUBLE => {
            if (is_static) { r.d = (t->CallStaticDoubleMethodA ?? @panic("JNI"))(env, cls, mid, first); } else { r.d = (t->CallDoubleMethodA ?? @panic("JNI"))(env, target.ref, mid, first); }
        },
        .BOOL => {
            if (is_static) { r.z = (t->CallStaticBooleanMethodA ?? @panic("JNI"))(env, cls, mid, first); } else { r.z = (t->CallBooleanMethodA ?? @panic("JNI"))(env, target.ref, mid, first); }
        },
        .OBJECT => {
            if (is_static) { r.l = (t->CallStaticObjectMethodA ?? @panic("JNI"))(env, cls, mid, first); } else { r.l = (t->CallObjectMethodA ?? @panic("JNI"))(env, target.ref, mid, first); }
        },
    }
    try check(env);
    return r;
}

// every call method: build the arguments, call, convert what comes back
<Args: type...>
public attach fn call_static_void(this: object&, name: str, sig: str, args: Args...) -> java_error!void {
    val f = frame(this.env);
    var a: std::vec<jni::jvalue> = {};
    comptime for (x) in args { a.push(jarg(this.env, &x)) catch @panic("out of memory"); }
    val r = try invoke(this, true, name, sig, a.items(), kind::VOID);
}
<Args: type...>
public attach fn call_static_int(this: object&, name: str, sig: str, args: Args...) -> java_error!i32 {
    val f = frame(this.env);
    var a: std::vec<jni::jvalue> = {};
    comptime for (x) in args { a.push(jarg(this.env, &x)) catch @panic("out of memory"); }
    return (try invoke(this, true, name, sig, a.items(), kind::INT)).i;
}
<Args: type...>
public attach fn call_static_long(this: object&, name: str, sig: str, args: Args...) -> java_error!i64 {
    val f = frame(this.env);
    var a: std::vec<jni::jvalue> = {};
    comptime for (x) in args { a.push(jarg(this.env, &x)) catch @panic("out of memory"); }
    return (try invoke(this, true, name, sig, a.items(), kind::LONG)).j;
}
<Args: type...>
public attach fn call_static_double(this: object&, name: str, sig: str, args: Args...) -> java_error!f64 {
    val f = frame(this.env);
    var a: std::vec<jni::jvalue> = {};
    comptime for (x) in args { a.push(jarg(this.env, &x)) catch @panic("out of memory"); }
    return (try invoke(this, true, name, sig, a.items(), kind::DOUBLE)).d;
}
<Args: type...>
public attach fn call_static_bool(this: object&, name: str, sig: str, args: Args...) -> java_error!bool {
    val f = frame(this.env);
    var a: std::vec<jni::jvalue> = {};
    comptime for (x) in args { a.push(jarg(this.env, &x)) catch @panic("out of memory"); }
    return (try invoke(this, true, name, sig, a.items(), kind::BOOL)).z != 0;
}
<Args: type...>
public attach fn call_static_object(this: object&, name: str, sig: str, args: Args...) -> java_error!object {
    val f = frame(this.env);
    var a: std::vec<jni::jvalue> = {};
    comptime for (x) in args { a.push(jarg(this.env, &x)) catch @panic("out of memory"); }
    return global(this.env, (try invoke(this, true, name, sig, a.items(), kind::OBJECT)).l);
}
<Args: type...>
public attach fn call_static_string(this: object&, name: str, sig: str, args: Args...) -> java_error!std::string {
    val f = frame(this.env);
    var a: std::vec<jni::jvalue> = {};
    comptime for (x) in args { a.push(jarg(this.env, &x)) catch @panic("out of memory"); }
    val o = try global(this.env, (try invoke(this, true, name, sig, a.items(), kind::OBJECT)).l);
    return o.to_string();
}
<Args: type...>
public attach fn call_void(this: object&, name: str, sig: str, args: Args...) -> java_error!void {
    val f = frame(this.env);
    var a: std::vec<jni::jvalue> = {};
    comptime for (x) in args { a.push(jarg(this.env, &x)) catch @panic("out of memory"); }
    val r = try invoke(this, false, name, sig, a.items(), kind::VOID);
}
<Args: type...>
public attach fn call_int(this: object&, name: str, sig: str, args: Args...) -> java_error!i32 {
    val f = frame(this.env);
    var a: std::vec<jni::jvalue> = {};
    comptime for (x) in args { a.push(jarg(this.env, &x)) catch @panic("out of memory"); }
    return (try invoke(this, false, name, sig, a.items(), kind::INT)).i;
}
<Args: type...>
public attach fn call_long(this: object&, name: str, sig: str, args: Args...) -> java_error!i64 {
    val f = frame(this.env);
    var a: std::vec<jni::jvalue> = {};
    comptime for (x) in args { a.push(jarg(this.env, &x)) catch @panic("out of memory"); }
    return (try invoke(this, false, name, sig, a.items(), kind::LONG)).j;
}
<Args: type...>
public attach fn call_bool(this: object&, name: str, sig: str, args: Args...) -> java_error!bool {
    val f = frame(this.env);
    var a: std::vec<jni::jvalue> = {};
    comptime for (x) in args { a.push(jarg(this.env, &x)) catch @panic("out of memory"); }
    return (try invoke(this, false, name, sig, a.items(), kind::BOOL)).z != 0;
}
<Args: type...>
public attach fn call_double(this: object&, name: str, sig: str, args: Args...) -> java_error!f64 {
    val f = frame(this.env);
    var a: std::vec<jni::jvalue> = {};
    comptime for (x) in args { a.push(jarg(this.env, &x)) catch @panic("out of memory"); }
    return (try invoke(this, false, name, sig, a.items(), kind::DOUBLE)).d;
}
<Args: type...>
public attach fn call_object(this: object&, name: str, sig: str, args: Args...) -> java_error!object {
    val f = frame(this.env);
    var a: std::vec<jni::jvalue> = {};
    comptime for (x) in args { a.push(jarg(this.env, &x)) catch @panic("out of memory"); }
    return global(this.env, (try invoke(this, false, name, sig, a.items(), kind::OBJECT)).l);
}

// a new instance of this class: its constructor's signature ("(I)V") and arguments
<Args: type...>
public attach fn new_object(this: object&, sig: str, args: Args...) -> java_error!object {
    val t = fns(this.env);
    var s = std::string::from(sig);
    val mid = (t->GetMethodID ?? @panic("JNI"))(this.env, this.ref, "<init>", s.c_str());
    try check(this.env);
    val f = frame(this.env);
    var a: std::vec<jni::jvalue> = {};
    comptime for (x) in args { a.push(jarg(this.env, &x)) catch @panic("out of memory"); }
    var first: jni::jvalue* = null;
    if (a.len > 0) {
        first = &a.items()[0];
    }
    return global(this.env, (t->NewObjectA ?? @panic("JNI"))(this.env, this.ref, mid, first));
}
