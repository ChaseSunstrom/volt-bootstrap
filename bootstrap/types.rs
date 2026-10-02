// Interned types. Equal types have equal TyIds.
use std::collections::HashMap;

/// an index into Types.list; the builtin types have the fixed ids below
pub type TyId = u32;

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum IntTy {
    I8,
    I16,
    I32,
    I64,
    I128,
    Isize,
    U8,
    U16,
    U32,
    U64,
    U128,
    Usize,
}

/// every int type; an int's TyId is INT_BASE + its index here, so the order is fixed
pub const INTS: [IntTy; 12] = {
    use IntTy::*;
    [I8, I16, I32, I64, I128, Isize, U8, U16, U32, U64, U128, Usize]
};

impl IntTy {
    pub fn signed(self) -> bool {
        use IntTy::*;
        matches!(self, I8 | I16 | I32 | I64 | I128 | Isize)
    }
    pub fn bits(self) -> u32 {
        use IntTy::*;
        match self {
            I8 | U8 => 8,
            I16 | U16 => 16,
            I32 | U32 => 32,
            I64 | U64 | Isize | Usize => 64,
            I128 | U128 => 128,
        }
    }
    pub fn name(self) -> &'static str {
        use IntTy::*;
        match self {
            I8 => "i8",
            I16 => "i16",
            I32 => "i32",
            I64 => "i64",
            I128 => "i128",
            Isize => "isize",
            U8 => "u8",
            U16 => "u16",
            U32 => "u32",
            U64 => "u64",
            U128 => "u128",
            Usize => "usize",
        }
    }
    /// the C type name
    pub fn c(self) -> &'static str {
        use IntTy::*;
        match self {
            I8 => "int8_t",
            I16 => "int16_t",
            I32 => "int32_t",
            I64 => "int64_t",
            I128 => "volt_i128",
            Isize => "ptrdiff_t",
            U8 => "uint8_t",
            U16 => "uint16_t",
            U32 => "uint32_t",
            U64 => "uint64_t",
            U128 => "volt_u128",
            Usize => "size_t",
        }
    }
    /// the unsigned C type of the same width, for wrapping arithmetic
    pub fn c_unsigned(self) -> &'static str {
        match self.bits() {
            8 => "uint8_t",
            16 => "uint16_t",
            32 => "uint32_t",
            64 => "uint64_t",
            _ => "volt_u128",
        }
    }
    /// whether the constant v is representable in this type
    pub fn fits(self, v: i128) -> bool {
        let b = self.bits();
        if self.signed() {
            b == 128 || (v >= -(1i128 << (b - 1)) && v < (1i128 << (b - 1)))
        } else {
            v >= 0 && (b >= 127 || v < (1i128 << b))
        }
    }
    /// lossless conversion from self to other; i64/isize and u64/usize don't widen into each other (same
    /// width, but distinct types)
    pub fn widens_to(self, other: IntTy) -> bool {
        if self == other {
            return true;
        }
        match (self.signed(), other.signed()) {
            (true, true) | (false, false) => self.bits() <= other.bits() && !(self.bits() == 64 && other.bits() == 64),
            (false, true) => self.bits() < other.bits(),
            (true, false) => false,
        }
    }
}

/// a type's structure; the u32 in Struct, Enum, Closure and TraitUnion indexes the checker's structs, enums,
/// closures and unions, and in Frame its fns
#[derive(Clone, PartialEq, Eq, Hash, Debug)]
pub enum Ty {
    Void,
    Never,
    Bool,
    TypeTy,
    Null,
    Str,
    CStr,
    VoidPtr,
    Float(u16),
    Int(IntTy),
    Ref(TyId), // T&: never null
    Ptr(TyId), // T*: raw, may be null
    Opt(TyId),
    Array(TyId, u64),
    Slice(TyId),
    /// element types, and a name per element (None when unnamed)
    Tuple(Vec<TyId>, Vec<Option<String>>),
    /// element type
    Range(TyId),
    Struct(u32),
    Enum(u32),
    ErrUnion(TyId, TyId), // error set (an Enum with is_error, or ANYERR), payload
    AnyErr,
    FnPtr(Vec<TyId>, TyId, bool), // extern "C" fn: a thin C function pointer
    FnVal(Vec<TyId>, TyId),       // fn(A) -> R: {fn, env}, can hold a closure
    Closure(u32),
    Frame(u32),      // an async fn instance's frame (locals + resume state)
    TraitUnion(u32), // trait used as a type
}

// ids of the types Types::new interns first, in this order
pub const VOID: TyId = 0;
pub const NEVER: TyId = 1;
pub const BOOL: TyId = 2;
pub const TYPE: TyId = 3;
pub const NULL: TyId = 4;
pub const STR: TyId = 5;
pub const CSTR: TyId = 6;
pub const VOIDPTR: TyId = 7;
pub const F16: TyId = 8;
pub const F32: TyId = 9;
pub const F64: TyId = 10;
pub const F128: TyId = 11;
pub const ANYERR: TyId = 12;
const INT_BASE: TyId = 13;
pub const I32: TyId = INT_BASE + 2;
pub const I64: TyId = INT_BASE + 3;
pub const U8: TyId = INT_BASE + 6;
pub const USIZE: TyId = INT_BASE + 11;

/// the fixed TyId of an int type
pub fn int(k: IntTy) -> TyId {
    INT_BASE + INTS.iter().position(|x| *x == k).unwrap() as TyId
}

/// the type interner: `list` holds each distinct type once, `map` finds its id
pub struct Types {
    pub list: Vec<Ty>,
    map: HashMap<Ty, TyId>,
}

impl Types {
    /// interns the builtins in the order the constants above assume
    pub fn new() -> Types {
        let mut t = Types { list: Vec::new(), map: HashMap::new() };
        for ty in [Ty::Void, Ty::Never, Ty::Bool, Ty::TypeTy, Ty::Null, Ty::Str, Ty::CStr, Ty::VoidPtr] {
            t.intern(ty);
        }
        for b in [16, 32, 64, 128] {
            t.intern(Ty::Float(b));
        }
        t.intern(Ty::AnyErr);
        for k in INTS {
            t.intern(Ty::Int(k));
        }
        t
    }
    /// the id of ty, adding it if it's new
    pub fn intern(&mut self, ty: Ty) -> TyId {
        if let Some(id) = self.map.get(&ty) {
            return *id;
        }
        let id = self.list.len() as TyId;
        self.list.push(ty.clone());
        self.map.insert(ty, id);
        id
    }
    pub fn get(&self, id: TyId) -> &Ty {
        &self.list[id as usize]
    }
    pub fn int_of(&self, id: TyId) -> Option<IntTy> {
        match self.get(id) {
            Ty::Int(k) => Some(*k),
            _ => None,
        }
    }
    pub fn is_float(&self, id: TyId) -> bool {
        matches!(self.get(id), Ty::Float(_))
    }
    /// types whose optional uses NULL as "none" (a raw pointer can be null itself, so its optional can't)
    pub fn is_niche(&self, id: TyId) -> bool {
        matches!(self.get(id), Ty::Ref(_) | Ty::CStr | Ty::FnPtr(..))
    }
    /// a raw pointer (T* or void*): may be null
    pub fn is_ptr(&self, id: TyId) -> bool {
        matches!(self.get(id), Ty::Ptr(_) | Ty::VoidPtr)
    }
    /// the builtin type a name stands for (`error` is the any-error set)
    pub fn primitive(name: &str) -> Option<TyId> {
        Some(match name {
            "void" => VOID,
            "never" => NEVER,
            "bool" => BOOL,
            "type" => TYPE,
            "str" => STR,
            "cstr" => CSTR,
            "f16" => F16,
            "f32" => F32,
            "f64" => F64,
            "f128" => F128,
            "error" => ANYERR,
            _ => return INTS.iter().find(|k| k.name() == name).map(|k| int(*k)),
        })
    }
}
