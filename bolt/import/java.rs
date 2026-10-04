// use { "Geom.java" } as NAME; (or "lib.jar", or use java { "classes" }) — Java classes called from
// Volt. bolt compiles the sources with javac, asks the JVM itself what the classes export
// (DESCRIBE: reflection, run on the JDK), and writes Volt that calls them through JNI: the JDK's
// jni.h, imported like any C header, and java_rt, a small runtime in the import's namespace. No
// shim and no C: the JVM starts on first use (or the one the process has is used), and each
// import loads its classes through a class loader of its own.
//
//   boolean, byte, char, short, int, long, float, double -> bool, i8, u16, i16, i32, i64, f32, f64
//   String -> str in, std::string out (null: ""); arrays of those and of String -> T[..] in (what
//   Java changes comes back), std::vec<T> out
//   an imported class or interface -> a handle (a global reference: a copy refers to the same
//   object); constructors are T::new(...), overloads stay overloads; as_S() for each imported
//   supertype S; an imported enum -> a Volt enum
//   a method that declares exceptions -> java_error!T; any other exception stops the program
//   public fields -> x() and set_x(v) (static ones on the class: T::x())
use super::{arg_path, fresh, save, stamp, volt_name, Made, Req};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

pub fn import(r: &Req) -> Result<(), String> {
    let home = jdk()?;
    let (mut sources, mut paths) = (Vec::new(), Vec::new());
    for a in &r.args {
        let p = arg_path(r, a);
        let ext = p.extension().map(|e| e.to_string_lossy().to_ascii_lowercase()).unwrap_or_default();
        if p.is_dir() || (p.is_file() && ext == "jar") {
            paths.push(p);
        } else if p.is_file() && ext == "java" {
            sources.push(p);
        } else if p.is_file() && ext == "class" {
            return Err(format!("use java {{ \"{a}\" }}: name the directory the classes are in (their packages' root)"));
        } else {
            return Err(format!("use java: there's no {}", p.display()));
        }
    }
    if sources.is_empty() && paths.is_empty() {
        return Err(format!("use java {{ \"Geom.java\" }} as {}: name Java sources, jars or class directories", r.alias));
    }
    let mut files = sources.clone();
    for p in &paths {
        class_files(p, &mut files);
    }
    let st = stamp(&files, &format!("java {} {} release={}", r.alias, home.display(), r.release));
    if fresh(r, &st) {
        return Ok(());
    }
    let out = {
        std::fs::create_dir_all(&r.out).map_err(|e| format!("can't make {}: {e}", r.out.display()))?;
        std::fs::canonicalize(&r.out).unwrap_or_else(|_| r.out.clone())
    };
    let sep = if cfg!(windows) { ";" } else { ":" };
    let tool = |n: &str| home.join("bin").join(n);

    // the sources, compiled (-parameters: their parameter names reach Volt)
    let mut roots = Vec::new();
    if !sources.is_empty() {
        let classes = out.join("classes");
        let _ = std::fs::remove_dir_all(&classes);
        let mut c = Command::new(tool("javac"));
        c.arg("-parameters").arg("-d").arg(&classes);
        if !paths.is_empty() {
            c.arg("-cp").arg(paths.iter().map(|p| p.display().to_string()).collect::<Vec<_>>().join(sep));
        }
        run(c.args(&sources), "javac couldn't compile the sources")?;
        roots.push(classes);
    }
    roots.extend(paths);
    let cp = roots.iter().map(|p| p.display().to_string()).collect::<Vec<_>>();

    // what they export
    let d = out.join("describe");
    std::fs::create_dir_all(&d).map_err(|e| format!("can't make {}: {e}", d.display()))?;
    crate::build::write_if_changed(&d.join("Describe.java"), DESCRIBE)?;
    run(Command::new(tool("javac")).arg("-d").arg(&d).arg(d.join("Describe.java")), "javac couldn't compile bolt's class reader")?;
    let desc = run(Command::new(tool("java")).arg("-cp").arg(&d).arg("Describe").arg(cp.join(sep)).args(&roots), "the classes can't be read")?;

    // the JDK's jni.h, where the Volt side imports it
    let jni = out.join("jni");
    std::fs::create_dir_all(&jni).map_err(|e| format!("can't make {}: {e}", jni.display()))?;
    let inc = home.join("include");
    let md = std::fs::read_dir(&inc).ok().and_then(|rd| rd.flatten().map(|e| e.path().join("jni_md.h")).find(|p| p.is_file())).ok_or(format!("use java: the JDK at {} has no include/*/jni_md.h", home.display()))?;
    for (from, name) in [(inc.join("jni.h"), "jni.h"), (md, "jni_md.h")] {
        let text = std::fs::read_to_string(&from).map_err(|e| format!("use java: can't read {}: {e}", from.display()))?;
        crate::build::write_if_changed(&jni.join(name), &text)?;
    }

    let (classes, left) = read(&desc);
    let volt = generate(&r.alias, &classes, left, &cp, &jni.join("jni.h"));
    let lib = home.join("lib").join("server");
    let flags = vec![format!("-L{}", lib.display()), format!("-Wl,-rpath,{}", lib.display()), "-ljvm".to_string()];
    save(r, &Made { volt, flags, deps: files }, &st)
}

/// the JDK: $JAVA_HOME, else the one whose javac is on PATH
fn jdk() -> Result<PathBuf, String> {
    let ok = |h: &Path| h.join("bin").join("javac").is_file() && h.join("include").join("jni.h").is_file();
    if let Some(h) = std::env::var_os("JAVA_HOME").map(PathBuf::from) {
        return if ok(&h) { Ok(h) } else { Err(format!("use java: $JAVA_HOME ({}) isn't a JDK: it needs bin/javac and include/jni.h", h.display())) };
    }
    let path = std::env::var_os("PATH").unwrap_or_default();
    std::env::split_paths(&path)
        .map(|d| d.join("javac"))
        .filter(|j| j.is_file())
        .filter_map(|j| std::fs::canonicalize(j).ok()?.parent()?.parent().map(Path::to_path_buf))
        .find(|h| ok(h))
        .ok_or_else(|| "use java: there's no JDK (javac and its jni.h): set $JAVA_HOME to one".to_string())
}

/// a command's output, or an error saying what went wrong
fn run(c: &mut Command, what: &str) -> Result<String, String> {
    let o = c.output().map_err(|e| format!("use java: can't run {:?}: {e}", c.get_program()))?;
    if !o.status.success() {
        return Err(format!("use java: {what}:\n{}{}", String::from_utf8_lossy(&o.stderr), String::from_utf8_lossy(&o.stdout)));
    }
    Ok(String::from_utf8_lossy(&o.stdout).into_owned())
}

/// a class directory's .class files, or the jar itself
fn class_files(p: &Path, out: &mut Vec<PathBuf>) {
    if p.is_file() {
        out.push(p.to_path_buf());
        return;
    }
    let Ok(rd) = std::fs::read_dir(p) else { return };
    let mut ps: Vec<PathBuf> = rd.flatten().map(|e| e.path()).collect();
    ps.sort();
    for x in ps {
        if x.is_dir() {
            class_files(&x, out);
        } else if x.extension().is_some_and(|e| e == "class") {
            out.push(x);
        }
    }
}

/// a Java program printing what classes export, a declaration a line (tab-separated). Its
/// arguments: the class path, then the directories and jars whose classes it reads.
///   class BINARY_NAME class|abstract|interface|enum, then super BINARY_NAME (every imported-or-not
///   supertype but Object), value NAME (an enum's), ctor THROWS DESCRIPTOR NAMES,
///   method NAME static|inst THROWS DESCRIPTOR NAMES, field NAME static|inst final|mut DESCRIPTOR; end
///   other NAME WHY
const DESCRIBE: &str = r#"import java.io.File;
import java.lang.reflect.*;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.file.*;
import java.util.*;
import java.util.jar.JarFile;

public class Describe {
    static String d(Class<?> c) {
        if (c.isPrimitive()) {
            return switch (c.getName()) {
                case "boolean" -> "Z";
                case "byte" -> "B";
                case "char" -> "C";
                case "short" -> "S";
                case "int" -> "I";
                case "long" -> "J";
                case "float" -> "F";
                case "double" -> "D";
                default -> "V";
            };
        }
        if (c.isArray()) {
            return c.getName().replace('.', '/');
        }
        return "L" + c.getName().replace('.', '/') + ";";
    }

    static String sig(Class<?>[] ps, Class<?> r) {
        StringBuilder b = new StringBuilder("(");
        for (Class<?> p : ps) {
            b.append(d(p));
        }
        return b.append(")").append(d(r)).toString();
    }

    static String names(Parameter[] ps) {
        StringJoiner j = new StringJoiner(",");
        for (Parameter p : ps) {
            j.add(p.getName());
        }
        return j.toString();
    }

    static void supers(Class<?> c, Set<Class<?>> out) {
        Class<?> s = c.getSuperclass();
        if (s != null && s != Object.class && out.add(s)) {
            supers(s, out);
        }
        for (Class<?> i : c.getInterfaces()) {
            if (out.add(i)) {
                supers(i, out);
            }
        }
    }

    static void classes(Path root, List<String> out) throws Exception {
        if (Files.isDirectory(root)) {
            try (var w = Files.walk(root)) {
                w.filter(p -> p.toString().endsWith(".class")).forEach(p -> out.add(root.relativize(p).toString().replace(File.separatorChar, '/')));
            }
        } else {
            try (JarFile j = new JarFile(root.toFile())) {
                j.stream().map(e -> e.getName()).filter(n -> n.endsWith(".class")).forEach(out::add);
            }
        }
    }

    public static void main(String[] a) throws Exception {
        String[] cp = a[0].split(File.pathSeparator);
        URL[] urls = new URL[cp.length];
        for (int i = 0; i < cp.length; i++) {
            urls[i] = new File(cp[i]).toURI().toURL();
        }
        ClassLoader l = new URLClassLoader(urls);
        List<String> files = new ArrayList<>();
        for (int i = 1; i < a.length; i++) {
            classes(Path.of(a[i]), files);
        }
        Collections.sort(files);
        for (String f : files) {
            if (f.endsWith("module-info.class") || f.endsWith("package-info.class")) {
                continue;
            }
            String n = f.substring(0, f.length() - 6).replace('/', '.');
            Class<?> c;
            try {
                c = Class.forName(n, false, l);
            } catch (Throwable t) {
                System.out.println("other\t" + n + "\tit can't be loaded: " + t);
                continue;
            }
            int mod = c.getModifiers();
            if (!Modifier.isPublic(mod) || c.isAnonymousClass() || c.isLocalClass() || c.isSynthetic() || c.isAnnotation()) {
                continue;
            }
            String kind = c.isEnum() ? "enum" : c.isInterface() ? "interface" : Modifier.isAbstract(mod) ? "abstract" : "class";
            System.out.println("class\t" + c.getName().replace('.', '/') + "\t" + kind);
            try {
                Set<Class<?>> ss = new LinkedHashSet<>();
                supers(c, ss);
                for (Class<?> s : ss) {
                    System.out.println("super\t" + s.getName().replace('.', '/'));
                }
                if (c.isEnum()) {
                    for (Object e : c.getEnumConstants()) {
                        System.out.println("value\t" + ((Enum<?>) e).name());
                    }
                }
                if (kind.equals("class")) {
                    Constructor<?>[] ks = c.getConstructors();
                    Arrays.sort(ks, Comparator.comparing((Constructor<?> k) -> sig(k.getParameterTypes(), void.class)));
                    for (Constructor<?> k : ks) {
                        System.out.println("ctor\t" + (k.getExceptionTypes().length > 0 ? 1 : 0) + "\t" + sig(k.getParameterTypes(), void.class) + "\t" + names(k.getParameters()));
                    }
                }
                Method[] ms = c.getMethods();
                Arrays.sort(ms, Comparator.comparing((Method m) -> m.getName()).thenComparing(m -> sig(m.getParameterTypes(), m.getReturnType())));
                for (Method m : ms) {
                    Class<?> dc = m.getDeclaringClass();
                    boolean st = Modifier.isStatic(m.getModifiers());
                    if (m.isBridge() || m.isSynthetic() || dc == Object.class || dc == Enum.class || dc == Record.class || (st && dc != c)) {
                        continue;
                    }
                    if (c.isEnum() && st && (m.getName().equals("values") || m.getName().equals("valueOf"))) {
                        continue;
                    }
                    System.out.println("method\t" + m.getName() + "\t" + (st ? "static" : "inst") + "\t" + (m.getExceptionTypes().length > 0 ? 1 : 0) + "\t" + sig(m.getParameterTypes(), m.getReturnType()) + "\t" + names(m.getParameters()));
                }
                Field[] fs = c.getFields();
                Arrays.sort(fs, Comparator.comparing(Field::getName));
                for (Field x : fs) {
                    int fm = x.getModifiers();
                    if (x.isEnumConstant() || x.isSynthetic() || (Modifier.isStatic(fm) && x.getDeclaringClass() != c)) {
                        continue;
                    }
                    System.out.println("field\t" + x.getName() + "\t" + (Modifier.isStatic(fm) ? "static" : "inst") + "\t" + (Modifier.isFinal(fm) ? "final" : "mut") + "\t" + d(x.getType()));
                }
            } catch (Throwable t) {
                System.out.println("other\t" + n + "\tits members can't be read: " + t);
            }
            System.out.println("end");
        }
    }
}
"#;

struct Member {
    name: String,
    is_static: bool,
    throws: bool,
    sig: String,
    params: Vec<String>,
}

struct Field {
    name: String,
    is_static: bool,
    is_final: bool,
    desc: String,
}

struct Class {
    bin: String,
    kind: String,
    supers: Vec<String>,
    values: Vec<String>,
    ctors: Vec<Member>,
    methods: Vec<Member>,
    fields: Vec<Field>,
}

/// DESCRIBE's output: the classes, and what can't be used at all
fn read(desc: &str) -> (Vec<Class>, Vec<String>) {
    let (mut classes, mut left) = (Vec::new(), Vec::new());
    let mut cur: Option<Class> = None;
    let member = |f: &[&str], name: &str, is_static: bool, k: usize| Member {
        name: name.to_string(),
        is_static,
        throws: f.get(k) == Some(&"1"),
        sig: f.get(k + 1).unwrap_or(&"").to_string(),
        params: f.get(k + 2).filter(|s| !s.is_empty()).map(|s| s.split(',').map(str::to_string).collect()).unwrap_or_default(),
    };
    for line in desc.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        let c = cur.as_mut();
        match (f[0], c) {
            ("class", _) if f.len() == 3 => cur = Some(Class { bin: f[1].to_string(), kind: f[2].to_string(), supers: vec![], values: vec![], ctors: vec![], methods: vec![], fields: vec![] }),
            ("super", Some(c)) if f.len() == 2 => c.supers.push(f[1].to_string()),
            ("value", Some(c)) if f.len() == 2 => c.values.push(f[1].to_string()),
            ("ctor", Some(c)) if f.len() >= 3 => c.ctors.push(member(&f, "<init>", false, 1)),
            ("method", Some(c)) if f.len() >= 5 => c.methods.push(member(&f, f[1], f[2] == "static", 3)),
            ("field", Some(c)) if f.len() == 5 => c.fields.push(Field { name: f[1].to_string(), is_static: f[2] == "static", is_final: f[3] == "final", desc: f[4].to_string() }),
            ("end", _) => classes.extend(cur.take()),
            ("other", _) if f.len() >= 3 => left.push(format!("{} ({})", f[1].replace('/', "."), f[2..].join(" "))),
            _ => {}
        }
    }
    (classes, left)
}

/// a class's Volt name: geo/Point is Point, geo/Outer$Inner Outer_Inner
fn volt_class(bin: &str) -> String {
    bin.rsplit('/').next().unwrap_or(bin).replace('$', "_")
}

/// a method descriptor's parameters and result: (I[DLgeo/Point;)V
fn split_desc(d: &str) -> Option<(Vec<String>, String)> {
    let inner = d.strip_prefix('(')?;
    let (ps, ret) = inner.split_once(')')?;
    let b = ps.as_bytes();
    let (mut out, mut i) = (Vec::new(), 0);
    while i < b.len() {
        let start = i;
        while b[i] == b'[' {
            i += 1;
        }
        if b[i] == b'L' {
            i += ps[i..].find(';')?;
        }
        i += 1;
        out.push(ps[start..i].to_string());
    }
    Some((out, ret.to_string()))
}

/// a Java type as Volt sees it
#[derive(Clone, PartialEq, Debug)]
enum JT {
    Void,
    /// a primitive, by its descriptor letter
    Prim(char),
    Str,
    /// an array of primitives (their letter) or of String ('T')
    Arr(char),
    /// an imported class or interface, by its Volt name
    Obj(String),
    Enum(String),
}

/// the primitives: descriptor letter, Volt type, JNI's name for it, jvalue's member, JNI's C type
const KINDS: [(char, &str, &str, &str, &str); 8] =
    [('Z', "bool", "Boolean", "z", "jboolean"), ('B', "i8", "Byte", "b", "jbyte"), ('C', "u16", "Char", "c", "jchar"), ('S', "i16", "Short", "s", "jshort"), ('I', "i32", "Int", "i", "jint"), ('J', "i64", "Long", "j", "jlong"), ('F', "f32", "Float", "f", "jfloat"), ('D', "f64", "Double", "d", "jdouble")];

fn prim(k: char) -> Option<&'static str> {
    KINDS.iter().find(|x| x.0 == k).map(|x| x.1)
}

struct Gen<'a> {
    alias: &'a str,
    /// the usable classes: binary name -> (Volt name, is an enum)
    names: BTreeMap<String, (String, bool)>,
    /// java_rt's cached classes, method and field IDs
    slots: String,
    n: usize,
    left: Vec<String>,
}

impl Gen<'_> {
    fn jt(&self, d: &str) -> Option<JT> {
        Some(match d {
            "V" => JT::Void,
            "Ljava/lang/String;" => JT::Str,
            "[Ljava/lang/String;" => JT::Arr('T'),
            _ => {
                if let Some(k) = d.strip_prefix('[') {
                    let k = k.chars().next().filter(|_| k.len() == 1)?;
                    prim(k)?;
                    JT::Arr(k)
                } else if d.len() == 1 {
                    let k = d.chars().next()?;
                    prim(k)?;
                    JT::Prim(k)
                } else {
                    let (v, is_enum) = self.names.get(d.strip_prefix('L')?.strip_suffix(';')?)?;
                    if *is_enum {
                        JT::Enum(v.clone())
                    } else {
                        JT::Obj(v.clone())
                    }
                }
            }
        })
    }

    /// the Volt type of a parameter (or field value) of this type
    fn ty_in(t: &JT) -> String {
        match t {
            JT::Prim(k) => prim(*k).unwrap_or("void").into(),
            JT::Str => "str".into(),
            JT::Arr('T') => "str[..]".into(),
            JT::Arr(k) => format!("{}[..]", prim(*k).unwrap_or("void")),
            JT::Obj(n) => format!("{n}&"),
            JT::Enum(n) => n.clone(),
            JT::Void => "void".into(),
        }
    }

    /// the Volt type of a result
    fn ty_out(t: &JT) -> String {
        match t {
            JT::Str => "std::string".into(),
            JT::Arr('T') => "std::vec<std::string>".into(),
            JT::Arr(k) => format!("std::vec<{}>", prim(*k).unwrap_or("void")),
            JT::Obj(n) => n.clone(),
            t => Self::ty_in(t),
        }
    }

    /// the JNI kind of a value: a primitive's letter, else L (an object)
    fn kind(t: &JT) -> char {
        match t {
            JT::Prim(k) => *k,
            JT::Void => 'V',
            _ => 'L',
        }
    }

    /// Volt value v as JNI's (statements before the call, the value, statements after it)
    fn raw(t: &JT, v: &str) -> (Vec<String>, String, Vec<String>) {
        match t {
            JT::Str => (vec![], format!("java_rt::jstr(j_e, {v})"), vec![]),
            JT::Arr('T') => (vec![], format!("java_rt::arr_T(j_e, {v})"), vec![]),
            // Java's changes to the array come back
            JT::Arr(k) => (vec![format!("val {v}_j = java_rt::arr_{k}(j_e, {v});")], format!("{v}_j"), vec![format!("java_rt::back_{k}(j_e, {v}_j, {v});")]),
            JT::Obj(_) => (vec![], format!("{v}.o.r"), vec![]),
            JT::Enum(n) => (vec![], format!("java_rt::to_{n}(j_e, {v})"), vec![]),
            _ => (vec![], v.to_string(), vec![]),
        }
    }

    /// the statements returning JNI result j_r as Volt's
    fn result(t: &JT) -> Vec<String> {
        match t {
            JT::Void => vec![],
            JT::Prim(_) => vec!["return j_r;".into()],
            JT::Str => vec!["return java_rt::take_str(j_e, j_r);".into()],
            JT::Arr(k) => vec![format!("return java_rt::take_{k}(j_e, j_r);")],
            JT::Obj(n) => vec![format!("val j_v: {n} = {{ o: java_rt::own(j_e, j_r) }};"), "return j_v;".into()],
            JT::Enum(n) => vec![format!("return java_rt::of_{n}(java_rt::ordinal(j_e, j_r));")],
        }
    }

    /// a new cached ID in java_rt
    fn slot(&mut self, ty: &str) -> String {
        self.n += 1;
        let s = format!("id{}", self.n);
        let _ = writeln!(self.slots, "    var {s}: jni::{ty} = null;");
        s
    }

    /// a parameter's Volt name, apart from the glue's locals (j_e, j_r...)
    fn param_name(n: &str, i: usize) -> String {
        let n = if n.is_empty() { format!("p{i}") } else { volt_name(n) };
        if n.starts_with("j_") || n == "this" {
            format!("{n}_")
        } else {
            n
        }
    }

    /// the lines every call starts with: the thread's JNIEnv, a local frame, the class
    fn start(&self, cv: &str, check: Option<&str>) -> Vec<String> {
        let mut l = vec!["val j_e = java_rt::env();".to_string(), "val j_f = java_rt::frame(j_e);".into()];
        if let Some(recv) = check {
            l.push(format!("java_rt::live({recv}, \"{}::{cv}\");", self.alias));
        }
        l.push(format!("val j_c = java_rt::class_{cv}(j_e);"));
        l
    }

    /// a constructor, a method or a field accessor as a Volt function, or why it's left out
    fn member(&mut self, cv: &str, is_enum: bool, m: &Member, seen: &mut BTreeSet<String>) -> Result<String, String> {
        let ctor = m.name == "<init>";
        let what = if ctor { format!("{cv}::new") } else { format!("{cv}::{}", m.name) };
        let (ps, ret) = split_desc(&m.sig).ok_or(format!("{what} (its descriptor)"))?;
        let ret = if ctor { JT::Obj(cv.to_string()) } else { self.jt(&ret).ok_or(format!("{what} (its return type)"))? };
        let (mut params, mut pre, mut args, mut post, mut key) = (Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new());
        for (i, d) in ps.iter().enumerate() {
            let pn = Self::param_name(m.params.get(i).map_or("", String::as_str), i);
            let t = self.jt(d).ok_or(format!("{what} (parameter {pn}'s type)"))?;
            params.push(format!("{pn}: {}", Self::ty_in(&t)));
            key.push(Self::ty_in(&t));
            let (p0, raw, p1) = Self::raw(&t, &pn);
            pre.extend(p0);
            args.push(format!("java_rt::jv_{}({raw})", Self::kind(&t)));
            post.extend(p1);
        }
        let vn = if ctor { "new".to_string() } else { volt_name(&m.name) };
        if !seen.insert(format!("{vn} {} ({})", m.is_static || ctor, key.join(", "))) {
            return Err(format!("{what} {} (an overload Volt sees as the same)", m.sig));
        }
        let rt = Self::ty_out(&ret);
        let rt = if m.throws { format!("java_error!{rt}") } else { rt };
        let mut head_params = Vec::new();
        if m.is_static || ctor {
            head_params.push(format!("static this: {cv}"));
        } else {
            head_params.push(format!("this: {cv}&"));
        }
        head_params.extend(params);
        let mut l = Vec::new();
        let recv = if m.is_static || ctor {
            l.extend(self.start(cv, None));
            "j_c".to_string()
        } else if is_enum {
            l.extend(self.start(cv, None));
            l.push(format!("val j_o = java_rt::to_{cv}(j_e, *this);"));
            "j_o".to_string()
        } else {
            l.extend(self.start(cv, Some("this.o.r")));
            "this.o.r".to_string()
        };
        let slot = self.slot("jmethodID");
        l.push(format!("val j_m = java_rt::mid(&java_rt::{slot}, j_e, j_c, {}, \"{}\", \"{}\");", m.is_static, m.name, m.sig));
        l.extend(pre);
        let a = if args.is_empty() {
            "null".to_string()
        } else {
            l.push(format!("val j_a: java_rt::jni::jvalue[{}] = {{ {} }};", args.len(), args.join(", ")));
            "&j_a[0]".to_string()
        };
        let k = Self::kind(&ret);
        let call = if ctor {
            format!("java_rt::new_obj(j_e, j_c, j_m, {a})")
        } else if m.is_static {
            format!("java_rt::scall_{k}(j_e, j_c, j_m, {a})")
        } else {
            format!("java_rt::call_{k}(j_e, {recv}, j_m, {a})")
        };
        l.push(if k == 'V' && !ctor { format!("{call};") } else { format!("val j_r = {call};") });
        l.extend(Self::check(m.throws));
        l.extend(post);
        l.extend(Self::result(&ret));
        Ok(Self::func(&format!("attach fn {vn}({}) -> {rt}", head_params.join(", ")), &l))
    }

    /// a declared exception is the caller's to handle; any other stops the program
    fn check(throws: bool) -> Vec<String> {
        if throws {
            vec!["if (java_rt::pending(j_e)) {".into(), "    return java_error::THROWN(java_rt::take_exception(j_e));".into(), "}".into()]
        } else {
            vec!["java_rt::thrown(j_e);".into()]
        }
    }

    fn func(head: &str, lines: &[String]) -> String {
        let mut f = format!("{head} {{\n");
        for x in lines {
            let _ = writeln!(f, "    {x}");
        }
        f.push_str("}\n");
        f
    }

    /// a public field's getter and (unless final) setter
    fn field(&mut self, cv: &str, is_enum: bool, f: &Field, taken: &BTreeSet<String>) -> Result<String, String> {
        let what = format!("{cv}::{}", f.name);
        let t = self.jt(&f.desc).ok_or(format!("{what} (its type)"))?;
        let vn = volt_name(&f.name);
        if taken.contains(&vn) {
            return Err(format!("{what} (a field with a method's name)"));
        }
        let (s, this) = if f.is_static { ("s", format!("static this: {cv}")) } else { ("", format!("this: {cv}&")) };
        let k = Self::kind(&t);
        let slot = self.slot("jfieldID");
        let (mut l, recv) = if f.is_static {
            (self.start(cv, None), "j_c")
        } else if is_enum {
            // an enum constant's field: the constant's object
            let mut l = self.start(cv, None);
            l.push(format!("val j_o = java_rt::to_{cv}(j_e, *this);"));
            (l, "j_o")
        } else {
            (self.start(cv, Some("this.o.r")), "this.o.r")
        };
        l.push(format!("val j_i = java_rt::fid(&java_rt::{slot}, j_e, j_c, {}, \"{}\", \"{}\");", f.is_static, f.name, f.desc));
        let mut get = l.clone();
        get.push(format!("val j_r = java_rt::{s}get_{k}(j_e, {recv}, j_i);"));
        get.push("java_rt::thrown(j_e);".into());
        get.extend(Self::result(&t));
        let mut out = Self::func(&format!("attach fn {vn}({this}) -> {}", Self::ty_out(&t)), &get);
        if !f.is_final && !taken.contains(&format!("set_{vn}")) {
            let (pre, raw, _) = Self::raw(&t, "v");
            let mut set = l;
            set.extend(pre);
            set.push(format!("java_rt::{s}set_{k}(j_e, {recv}, j_i, {raw});"));
            set.push("java_rt::thrown(j_e);".into());
            let _ = write!(out, "\n{}", Self::func(&format!("attach fn set_{vn}({this}, v: {}) -> void", Self::ty_in(&t)), &set));
        }
        Ok(out)
    }
}

/// the Volt side: java_rt, the error type, a struct (or enum) per class with its functions
fn generate(alias: &str, classes: &[Class], mut left: Vec<String>, cp: &[String], jni_h: &Path) -> String {
    // two classes with one Volt name: neither is used
    let mut count: BTreeMap<String, usize> = BTreeMap::new();
    for c in classes {
        *count.entry(volt_class(&c.bin)).or_default() += 1;
    }
    let mut names = BTreeMap::new();
    for c in classes {
        let v = volt_class(&c.bin);
        if count[&v] > 1 || v == "java_rt" || v == "java_error" {
            left.push(format!("{} (another class is called {v})", c.bin.replace('/', ".")));
        } else {
            names.insert(c.bin.clone(), (v, c.kind == "enum"));
        }
    }
    let mut g = Gen { alias, names, slots: String::new(), n: 0, left: Vec::new() };
    let mut decls = String::new();
    let mut helpers = String::new();
    for c in classes {
        let Some((cv, is_enum)) = g.names.get(&c.bin).cloned() else { continue };
        let dotted = c.bin.replace('/', ".");
        let _ = write!(g.slots, "    var cls_{cv}: jni::jclass = null;\n");
        let _ = write!(helpers, "    fn class_{cv}(e: jni::JNIEnv*) -> jni::jclass {{\n        return cls(&cls_{cv}, e, \"{dotted}\");\n    }}\n");
        if is_enum {
            let mut body = String::new();
            let mut to = format!("    fn to_{cv}(e: jni::JNIEnv*, x: {alias}::{cv}) -> jni::jobject {{\n        val c = class_{cv}(e);\n        match (x) {{\n");
            let mut of = format!("    fn of_{cv}(i: i32) -> {alias}::{cv} {{\n");
            for (i, v) in c.values.iter().enumerate() {
                let vv = volt_name(v);
                let _ = writeln!(body, "    {vv} = {i},");
                let slot = g.slot("jfieldID");
                let _ = writeln!(to, "            .{vv} => {{ return sget_L(e, c, fid(&{slot}, e, c, true, \"{v}\", \"L{};\")); }},", c.bin);
                let _ = writeln!(of, "        if (i == {i}) {{\n            return {alias}::{cv}::{vv};\n        }}");
            }
            to.push_str("        }\n    }\n");
            let first = c.values.first().map_or(String::new(), |v| volt_name(v));
            let _ = write!(of, "        return {alias}::{cv}::{first};\n    }}\n");
            helpers.push_str(&to);
            helpers.push_str(&of);
            let _ = write!(decls, "\n// the Java enum {dotted}\nenum {cv}: i32 {{\n{body}}}\n");
        } else {
            let what = match c.kind.as_str() {
                "interface" => "interface",
                "abstract" => "abstract class",
                _ => "class",
            };
            let _ = write!(decls, "\n// the Java {what} {dotted}: a reference to an object (a copy refers to the same one)\nstruct {cv} {{\n    o: java_rt::ref = {{}};\n}}\n\n");
            let _ = write!(decls, "attach fn is_null(this: {cv}&) -> bool {{\n    return this.o.r == null;\n}}\n");
            for s in &c.supers {
                if let Some((sv, false)) = g.names.get(s).cloned() {
                    let _ = write!(decls, "\n// as a {}: the same object\nattach fn as_{sv}(this: {cv}&) -> {sv} {{\n    return {{ o: copy this.o }};\n}}\n", s.replace('/', "."));
                }
            }
        }
        let mut seen = BTreeSet::new();
        let mut taken: BTreeSet<String> = c.methods.iter().filter(|m| split_desc(&m.sig).is_some_and(|(p, _)| p.is_empty())).map(|m| volt_name(&m.name)).collect();
        taken.extend(c.methods.iter().map(|m| volt_name(&m.name)).filter(|n| n.starts_with("set_")));
        for m in c.ctors.iter().chain(&c.methods) {
            match g.member(&cv, is_enum, m, &mut seen) {
                Ok(f) => {
                    let _ = write!(decls, "\n{f}");
                }
                Err(why) => g.left.push(why),
            }
        }
        for f in &c.fields {
            match g.field(&cv, is_enum, f, &taken) {
                Ok(f) => {
                    let _ = write!(decls, "\n{f}");
                }
                Err(why) => g.left.push(why),
            }
        }
    }
    left.extend(g.left);

    let cps = cp.iter().map(|p| format!("\"{}\"", p.replace('\\', "\\\\").replace('"', "\\\""))).collect::<Vec<_>>();
    let mut rt = RUNTIME.replace("{JNI}", &jni_h.display().to_string().replace('\\', "\\\\")).replace("{N}", &cps.len().to_string()).replace("{CP}", &cps.join(", "));
    rt.push_str(&kinds());
    let mut volt = format!("// use java {{ ... }} as {alias}: the classes' public API, called through JNI (written by bolt import)\n\nnamespace java_rt {{\n{rt}\n{}\n{helpers}}}\n", g.slots);
    volt.push_str("\n// an exception a Java method declares (its throws), as its toString()\nerror java_error {\n    THROWN: std::string,\n}\n");
    volt.push_str(&decls);
    if !left.is_empty() {
        volt.push_str("\n// left out (Volt can't call these):\n");
        for l in &left {
            let _ = writeln!(volt, "//   {l}");
        }
    }
    volt
}

/// java_rt's functions for each primitive (and objects): jvalues, calls, fields, arrays
fn kinds() -> String {
    let mut s = String::new();
    let all = KINDS.iter().map(|k| (k.0, k.1, k.2, k.3)).chain([('L', "jni::jobject", "Object", "l")]);
    for (k, vt, jn, uf) in all {
        // bool <-> jboolean
        let (to_j, of_j) = if k == 'Z' { ("bz", " != 0") } else { ("", "") };
        if k == 'Z' {
            let _ = write!(s, "    fn jv_Z(x: bool) -> jni::jvalue {{\n        var v: jni::jvalue = {{ z: 0 }};\n        if (x) {{\n            v.z = 1;\n        }}\n        return v;\n    }}\n");
        } else {
            let _ = write!(s, "    fn jv_{k}(x: {vt}) -> jni::jvalue {{\n        var v: jni::jvalue = {{ {uf}: x }};\n        return v;\n    }}\n");
        }
        let _ = write!(
            s,
            "    fn call_{k}(e: jni::JNIEnv*, o: jni::jobject, m: jni::jmethodID, a: jni::jvalue*) -> {vt} {{\n        return (fns(e)->Call{jn}MethodA ?? @panic(\"JNI\"))(e, o, m, a){of_j};\n    }}\n    fn scall_{k}(e: jni::JNIEnv*, c: jni::jclass, m: jni::jmethodID, a: jni::jvalue*) -> {vt} {{\n        return (fns(e)->CallStatic{jn}MethodA ?? @panic(\"JNI\"))(e, c, m, a){of_j};\n    }}\n"
        );
        let _ = write!(
            s,
            "    fn get_{k}(e: jni::JNIEnv*, o: jni::jobject, f: jni::jfieldID) -> {vt} {{\n        return (fns(e)->Get{jn}Field ?? @panic(\"JNI\"))(e, o, f){of_j};\n    }}\n    fn sget_{k}(e: jni::JNIEnv*, c: jni::jclass, f: jni::jfieldID) -> {vt} {{\n        return (fns(e)->GetStatic{jn}Field ?? @panic(\"JNI\"))(e, c, f){of_j};\n    }}\n    fn set_{k}(e: jni::JNIEnv*, o: jni::jobject, f: jni::jfieldID, x: {vt}) -> void {{\n        (fns(e)->Set{jn}Field ?? @panic(\"JNI\"))(e, o, f, {to_j}(x));\n    }}\n    fn sset_{k}(e: jni::JNIEnv*, c: jni::jclass, f: jni::jfieldID, x: {vt}) -> void {{\n        (fns(e)->SetStatic{jn}Field ?? @panic(\"JNI\"))(e, c, f, {to_j}(x));\n    }}\n"
        );
    }
    for (k, vt, jn, _, ct) in KINDS {
        let _ = write!(
            s,
            "    fn arr_{k}(e: jni::JNIEnv*, xs: {vt}[..]) -> jni::jobject {{\n        val a = (fns(e)->New{jn}Array ?? @panic(\"JNI\"))(e, @cast<i32>(xs.len));\n        if (xs.len > 0) {{\n            (fns(e)->Set{jn}ArrayRegion ?? @panic(\"JNI\"))(e, a, 0, @cast<i32>(xs.len), @cast<jni::{ct}*>(xs.ptr));\n        }}\n        return a;\n    }}\n    // what Java changed in the array, back in Volt's\n    fn back_{k}(e: jni::JNIEnv*, a: jni::jobject, xs: {vt}[..]) -> void {{\n        if (xs.len > 0) {{\n            (fns(e)->Get{jn}ArrayRegion ?? @panic(\"JNI\"))(e, a, 0, @cast<i32>(xs.len), @cast<jni::{ct}*>(xs.ptr));\n        }}\n    }}\n    fn take_{k}(e: jni::JNIEnv*, a: jni::jobject) -> std::vec<{vt}> {{\n        var out: std::vec<{vt}> = {{}};\n        if (a == null) {{\n            return out;\n        }}\n        val n = (fns(e)->GetArrayLength ?? @panic(\"JNI\"))(e, a);\n        if (n == 0) {{\n            return out;\n        }}\n        val p = (fns(e)->Get{jn}ArrayElements ?? @panic(\"JNI\"))(e, a, null);\n        for (x) in @slice(@cast<{vt}*>(p), @cast<usize>(n)) {{\n            out.push(x) catch @panic(\"out of memory\");\n        }}\n        (fns(e)->Release{jn}ArrayElements ?? @panic(\"JNI\"))(e, a, p, 2); // JNI_ABORT: nothing to copy back\n        return out;\n    }}\n"
        );
    }
    s
}

/// java_rt's fixed part: the JVM, references, exceptions, strings, the class loader
const RUNTIME: &str = r#"    use { "{JNI}" } as jni;

    // the process's JVM: the one already running (another use java started it), else a new one
    var jvm: jni::JavaVM* = null;

    fn env() -> jni::JNIEnv* {
        var envp: void* = null;
        if (jvm == null) {
            var n: i32 = 0;
            jni::JNI_GetCreatedJavaVMs(&jvm, 1, &n);
            if (n == 0) {
                jvm = null;
                var args: jni::JavaVMInitArgs = { version: jni::JNI_VERSION_10, nOptions: 0, options: null, ignoreUnrecognized: 1 };
                if (jni::JNI_CreateJavaVM(&jvm, &envp, &args) != jni::JNI_OK) {
                    @panic("Java: the JVM didn't start");
                }
                return @cast<jni::JNIEnv*>(envp);
            }
        }
        if (((*jvm)->GetEnv ?? @panic("JNI"))(jvm, &envp, jni::JNI_VERSION_10) != jni::JNI_OK) {
            ((*jvm)->AttachCurrentThread ?? @panic("JNI"))(jvm, &envp, null);
        }
        return @cast<jni::JNIEnv*>(envp);
    }

    fn fns(e: jni::JNIEnv*) -> jni::JNINativeInterface_* {
        return @cast<jni::JNINativeInterface_*>(*e);
    }

    fn bz(x: bool) -> u8 {
        if (x) {
            return 1;
        }
        return 0;
    }

    // a JNI local frame until this is deleted: the local references a call makes go with it
    struct local_frame {
        e: jni::JNIEnv* = null;
    }

    fn frame(e: jni::JNIEnv*) -> local_frame {
        (fns(e)->PushLocalFrame ?? @panic("JNI"))(e, 32);
        return { e: e };
    }

    attach fn delete(this: local_frame&) -> void {
        (fns(this.e)->PopLocalFrame ?? @panic("JNI"))(this.e, null);
    }

    // a global reference to a Java object: a copy refers to the same object
    struct ref {
        r: jni::jobject = null;
    }

    attach fn delete(this: ref&) -> void {
        if (this.r != null) {
            val e = env();
            (fns(e)->DeleteGlobalRef ?? @panic("JNI"))(e, this.r);
            this.r = null;
        }
    }

    attach fn copy(this: ref&) -> ref {
        if (this.r == null) {
            return {};
        }
        val e = env();
        return { r: (fns(e)->NewGlobalRef ?? @panic("JNI"))(e, this.r) };
    }

    fn own(e: jni::JNIEnv*, local: jni::jobject) -> ref {
        if (local == null) {
            return {};
        }
        return { r: (fns(e)->NewGlobalRef ?? @panic("JNI"))(e, local) };
    }

    fn live(r: jni::jobject, what: str) -> void {
        if (r == null) {
            @panic(std::fmt::format("{} is empty: Java never made it, or gave back null", what).as_str());
        }
    }

    fn pending(e: jni::JNIEnv*) -> bool {
        return (fns(e)->ExceptionCheck ?? @panic("JNI"))(e) != 0;
    }

    // the pending exception's toString(); it's cleared
    fn take_exception(e: jni::JNIEnv*) -> std::string {
        val t = fns(e);
        val ex = (t->ExceptionOccurred ?? @panic("JNI"))(e);
        (t->ExceptionClear ?? @panic("JNI"))(e);
        var msg = std::string::from("a Java exception");
        val c = (t->GetObjectClass ?? @panic("JNI"))(e, ex);
        val m = (t->GetMethodID ?? @panic("JNI"))(e, c, "toString", "()Ljava/lang/String;");
        if (m != null) {
            val s = (t->CallObjectMethodA ?? @panic("JNI"))(e, ex, m, null);
            if ((t->ExceptionCheck ?? @panic("JNI"))(e) == 0) {
                msg = take_str(e, s);
            }
            (t->ExceptionClear ?? @panic("JNI"))(e);
        }
        return msg;
    }

    // an exception the method doesn't declare: the program stops, with its text
    fn thrown(e: jni::JNIEnv*) -> void {
        if (pending(e)) {
            val m = take_exception(e);
            @panic(m.as_str());
        }
    }

    fn jstr(e: jni::JNIEnv*, s: str) -> jni::jobject {
        var n = std::string::from(s);
        return (fns(e)->NewStringUTF ?? @panic("JNI"))(e, n.c_str());
    }

    fn take_str(e: jni::JNIEnv*, s: jni::jobject) -> std::string {
        if (s == null) {
            return std::string::from("");
        }
        val t = fns(e);
        val chars = (t->GetStringUTFChars ?? @panic("JNI"))(e, s, null) ?? return std::string::from("");
        val n = (t->GetStringUTFLength ?? @panic("JNI"))(e, s);
        val out = std::string::from(@cast<str>(@slice(@cast<u8*>(chars), @cast<usize>(n))));
        (t->ReleaseStringUTFChars ?? @panic("JNI"))(e, s, chars);
        return out;
    }

    var string_c: jni::jclass = null;

    fn arr_T(e: jni::JNIEnv*, xs: str[..]) -> jni::jobject {
        val t = fns(e);
        if (string_c == null) {
            string_c = (t->NewGlobalRef ?? @panic("JNI"))(e, (t->FindClass ?? @panic("JNI"))(e, "java/lang/String"));
        }
        val a = (t->NewObjectArray ?? @panic("JNI"))(e, @cast<i32>(xs.len), string_c, null);
        for (i) in 0..xs.len {
            val s = jstr(e, xs[i]);
            (t->SetObjectArrayElement ?? @panic("JNI"))(e, a, @cast<i32>(i), s);
            (t->DeleteLocalRef ?? @panic("JNI"))(e, s);
        }
        return a;
    }

    fn take_T(e: jni::JNIEnv*, a: jni::jobject) -> std::vec<std::string> {
        var out: std::vec<std::string> = {};
        if (a == null) {
            return out;
        }
        val t = fns(e);
        val n = (t->GetArrayLength ?? @panic("JNI"))(e, a);
        for (i) in 0..n {
            val s = (t->GetObjectArrayElement ?? @panic("JNI"))(e, a, i);
            out.push(take_str(e, s)) catch @panic("out of memory");
            (t->DeleteLocalRef ?? @panic("JNI"))(e, s);
        }
        return out;
    }

    // this import's classes come from a class loader of its own, over its class path
    var loader_ref: jni::jobject = null;
    var load_mid: jni::jmethodID = null;

    fn loader(e: jni::JNIEnv*) -> jni::jobject {
        if (loader_ref != null) {
            return loader_ref;
        }
        val t = fns(e);
        val j_f = frame(e);
        val cp: str[{N}] = { {CP} };
        val file_c = (t->FindClass ?? @panic("JNI"))(e, "java/io/File");
        val uri_c = (t->FindClass ?? @panic("JNI"))(e, "java/net/URI");
        val url_c = (t->FindClass ?? @panic("JNI"))(e, "java/net/URL");
        val loader_c = (t->FindClass ?? @panic("JNI"))(e, "java/net/URLClassLoader");
        val file_new = (t->GetMethodID ?? @panic("JNI"))(e, file_c, "<init>", "(Ljava/lang/String;)V");
        val to_uri = (t->GetMethodID ?? @panic("JNI"))(e, file_c, "toURI", "()Ljava/net/URI;");
        val to_url = (t->GetMethodID ?? @panic("JNI"))(e, uri_c, "toURL", "()Ljava/net/URL;");
        val loader_new = (t->GetMethodID ?? @panic("JNI"))(e, loader_c, "<init>", "([Ljava/net/URL;)V");
        val urls = (t->NewObjectArray ?? @panic("JNI"))(e, {N}, url_c, null);
        for (i) in 0..cp.len {
            val a: jni::jvalue[1] = { jv_L(jstr(e, cp[i])) };
            val file = (t->NewObjectA ?? @panic("JNI"))(e, file_c, file_new, &a[0]);
            val uri = (t->CallObjectMethodA ?? @panic("JNI"))(e, file, to_uri, null);
            val url = (t->CallObjectMethodA ?? @panic("JNI"))(e, uri, to_url, null);
            thrown(e);
            (t->SetObjectArrayElement ?? @panic("JNI"))(e, urls, @cast<i32>(i), url);
        }
        val a: jni::jvalue[1] = { jv_L(urls) };
        val l = (t->NewObjectA ?? @panic("JNI"))(e, loader_c, loader_new, &a[0]);
        thrown(e);
        load_mid = (t->GetMethodID ?? @panic("JNI"))(e, loader_c, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
        loader_ref = (t->NewGlobalRef ?? @panic("JNI"))(e, l);
        return loader_ref;
    }

    // a class by its binary name (geo.Point), loaded once
    fn cls(slot: jni::jclass*, e: jni::JNIEnv*, name: str) -> jni::jclass {
        if (*slot == null) {
            val j_f = frame(e);
            val l = loader(e);
            val a: jni::jvalue[1] = { jv_L(jstr(e, name)) };
            val c = (fns(e)->CallObjectMethodA ?? @panic("JNI"))(e, l, load_mid, &a[0]);
            thrown(e);
            *slot = (fns(e)->NewGlobalRef ?? @panic("JNI"))(e, c);
        }
        return *slot;
    }

    fn mid(slot: jni::jmethodID*, e: jni::JNIEnv*, c: jni::jclass, is_static: bool, name: str, sig: str) -> jni::jmethodID {
        if (*slot == null) {
            var n = std::string::from(name);
            var s = std::string::from(sig);
            if (is_static) {
                *slot = (fns(e)->GetStaticMethodID ?? @panic("JNI"))(e, c, n.c_str(), s.c_str());
            } else {
                *slot = (fns(e)->GetMethodID ?? @panic("JNI"))(e, c, n.c_str(), s.c_str());
            }
            thrown(e);
        }
        return *slot;
    }

    fn fid(slot: jni::jfieldID*, e: jni::JNIEnv*, c: jni::jclass, is_static: bool, name: str, sig: str) -> jni::jfieldID {
        if (*slot == null) {
            var n = std::string::from(name);
            var s = std::string::from(sig);
            if (is_static) {
                *slot = (fns(e)->GetStaticFieldID ?? @panic("JNI"))(e, c, n.c_str(), s.c_str());
            } else {
                *slot = (fns(e)->GetFieldID ?? @panic("JNI"))(e, c, n.c_str(), s.c_str());
            }
            thrown(e);
        }
        return *slot;
    }

    fn new_obj(e: jni::JNIEnv*, c: jni::jclass, m: jni::jmethodID, a: jni::jvalue*) -> jni::jobject {
        return (fns(e)->NewObjectA ?? @panic("JNI"))(e, c, m, a);
    }

    fn call_V(e: jni::JNIEnv*, o: jni::jobject, m: jni::jmethodID, a: jni::jvalue*) -> void {
        (fns(e)->CallVoidMethodA ?? @panic("JNI"))(e, o, m, a);
    }

    fn scall_V(e: jni::JNIEnv*, c: jni::jclass, m: jni::jmethodID, a: jni::jvalue*) -> void {
        (fns(e)->CallStaticVoidMethodA ?? @panic("JNI"))(e, c, m, a);
    }

    // an enum constant's ordinal
    var enum_c: jni::jclass = null;
    var ordinal_m: jni::jmethodID = null;

    fn ordinal(e: jni::JNIEnv*, o: jni::jobject) -> i32 {
        if (o == null) {
            @panic("Java gave back a null enum");
        }
        val t = fns(e);
        if (enum_c == null) {
            enum_c = (t->NewGlobalRef ?? @panic("JNI"))(e, (t->FindClass ?? @panic("JNI"))(e, "java/lang/Enum"));
        }
        val r = call_I(e, o, mid(&ordinal_m, e, enum_c, false, "ordinal", "()I"), null);
        thrown(e);
        return r;
    }
"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn import_java_descriptors() {
        assert_eq!(split_desc("(I[DLgeo/Point;[Ljava/lang/String;)V"), Some((vec!["I".into(), "[D".into(), "Lgeo/Point;".into(), "[Ljava/lang/String;".into()], "V".into())));
        assert_eq!(split_desc("()Ljava/lang/String;"), Some((vec![], "Ljava/lang/String;".into())));
        let mut names = BTreeMap::new();
        names.insert("geo/Point".to_string(), ("Point".to_string(), false));
        names.insert("geo/Color".to_string(), ("Color".to_string(), true));
        let g = Gen { alias: "geo", names, slots: String::new(), n: 0, left: vec![] };
        assert_eq!(g.jt("I"), Some(JT::Prim('I')));
        assert_eq!(g.jt("[J"), Some(JT::Arr('J')));
        assert_eq!(g.jt("[Ljava/lang/String;"), Some(JT::Arr('T')));
        assert_eq!(g.jt("Lgeo/Point;"), Some(JT::Obj("Point".into())));
        assert_eq!(g.jt("Lgeo/Color;"), Some(JT::Enum("Color".into())));
        assert_eq!(g.jt("Ljava/util/List;"), None);
        assert_eq!(g.jt("[[I"), None);
        assert_eq!(g.jt("[Lgeo/Point;"), None);
        assert_eq!(volt_class("geo/Outer$Inner"), "Outer_Inner");
    }

    #[test]
    fn import_java_read() {
        let desc = "class\tgeo/Point\tclass\nsuper\tgeo/Shape\nctor\t0\t(DD)V\tx,y\nmethod\tdist\tinst\t0\t(Lgeo/Point;)D\tother\nmethod\tparse\tstatic\t1\t(Ljava/lang/String;)Lgeo/Point;\ts\nfield\tx\tinst\tmut\tD\nend\nother\tgeo.Broken\tit can't be loaded: x\n";
        let (cs, left) = read(desc);
        assert_eq!(cs.len(), 1);
        let c = &cs[0];
        assert_eq!((c.bin.as_str(), c.kind.as_str(), c.supers.clone()), ("geo/Point", "class", vec!["geo/Shape".to_string()]));
        assert_eq!(c.ctors[0].params, ["x", "y"]);
        assert!(c.methods[1].is_static && c.methods[1].throws);
        assert_eq!(c.fields[0].name, "x");
        assert_eq!(left, ["geo.Broken (it can't be loaded: x)"]);
    }
}
