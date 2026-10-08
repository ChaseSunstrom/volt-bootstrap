// JavaScript calls shapelib (voltc bindings --lang node and --lang js): a generic's instances, a
// struct held by a class with methods, owned values passed in, a Volt trait as any object with its
// methods both ways, callbacks taking and giving text, handles and errors, closures given back as
// functions, and lists as arrays
const m = require("./shapelib");

// JavaScript's own shape: Volt calls its methods, and closes one it was given when it's done
class Circle {
    constructor(r) {
        this.r = r;
    }
    area() {
        return 3 * this.r * this.r;
    }
    name() {
        return "circle";
    }
    grow(by) {
        this.r += by;
    }
    close() {
        console.log("circle gone");
    }
}

// a callback's error: Volt gets the error a thrown VoltError names
function twice(x) {
    if (x > 5) {
        throw m.voltError(m.bank_error.OVERDRAWN);
    }
    return x * 2;
}

// what C and C++ don't print: an E!void callback, closures given back giving E!void and a str
function extras() {
    let ok = true;
    try {
        m.checked((x) => {
            if (x <= 0) {
                throw m.voltError(m.bank_error.OVERDRAWN);
            }
        }, 1);
    } catch (e) {
        ok = false;
    }
    let err = "";
    try {
        m.checked(() => {
            throw m.voltError(m.bank_error.OVERDRAWN);
        }, 1);
    } catch (e) {
        err = e.code;
    }
    console.log("checked", ok, err);
    const lim = m.limiter();
    let under = true;
    try {
        lim(3);
    } catch (e) {
        under = false;
    }
    let over = "";
    try {
        lim(12);
    } catch (e) {
        over = e.code;
    }
    console.log("limit", under, over);
    lim.close();
    const sign = m.labeler();
    console.log("sign", sign(5), sign(-1));
    sign.close();
}

// what the addon refuses (it prints only when it doesn't): a callback's exception is the call's, an
// instance lent to a callback is let go of when it returns, one lent to a call that hasn't returned
// can't be closed or given away, and a call can't be given the same instance twice
function refuses(what, f, msg) {
    try {
        f();
    } catch (e) {
        if (!e.message.includes(msg)) {
            console.log("wrong error:", what, e.message);
        }
        return;
    }
    console.log("accepted:", what);
}

function checks() {
    const a = m.account.open("checks");
    let saved = null;
    refuses("a callback's throw", () => m.visit(a, (x) => {
        saved = x;
        throw new Error("thrown");
    }), "thrown");
    refuses("a lent instance after its callback", () => saved.get(), "closed");
    refuses("closing an instance a call holds", () => m.visit(a, () => {
        a.close();
        return 0;
    }), "hasn't returned");
    refuses("giving it away meanwhile", () => m.visit(a, () => m.close_account(a)), "hasn't returned");
    refuses("giving one twice", () => m.close_all([a, a]), "twice");
    refuses("a closed function", () => {
        const d = m.doubler();
        d.close();
        d(1);
    }, "closed");
    a.get();
    a.close();
}

// lists (arrays both ways), arrays of text and handles, null for none
function lists() {
    const a = m.account.open("ann");
    a.deposit(5);
    const b = m.account.open("bobby");
    b.deposit(9);
    const ab = [a, b];
    const os = m.owners(ab);
    console.log("owners", os.length, os[0], os[1]);
    const rich = m.richest(ab);
    console.log("richest", rich, "after", a.get(), b.get());
    const opened = m.open_all(["cy", "dee"]);
    console.log("opened", opened.length, opened[1].owner());
    for (const x of opened) {
        x.close();
    }
    const sq = m.squares_upto(4);
    console.log("squares", sq.length, sq[3], "sum", m.sum_all(sq));
    const parts = ["a", "b", "c"];
    console.log("joined", m.joined(parts, "-"), "total", m.total_len(parts));
    console.log(`${m.greeting("ann")}; ${m.greeting(null)}`);
    const n1 = m.nickname(a);
    const n2 = m.nickname(b);
    console.log("nick", n1 !== null ? 1 : 0, n1, n2 !== null ? 1 : 0);
    const c = m.open_if("eve", true);
    const d = m.open_if("x", false);
    console.log("open_if", c !== null ? 1 : 0, d === null ? 1 : 0);
    const c1 = m.close_if(c);
    console.log("close_if", c1, m.close_if(null));
    console.log("close_all", m.close_all(ab));
    console.log("some", m.count_some([1, null, 3]));
    console.log("rows", m.total_rows([[1, 2], [3]]));
    console.log("lists closed", m.closed_accounts());
}

extras();
console.log("biggest", m.biggest_i32([3, 9, 4]), m.biggest_f64([1.5, 0.5]));
const a = m.account.open("ann");
a.deposit(250);
a.rename("bea");
let n = a.deposit(50);
console.log("account", a.owner(), n);
n = m.visit(a, (x) => x.deposit(1));
console.log("visit", n, "get", a.get());
n = m.close_account(a);
console.log("closed", n, m.closed_accounts());
const c = new Circle(1);
console.log(m.describe(c));
console.log("grown", m.grow_twice(new Circle(1)));
const sq = m.make_square(2);
sq.grow(1);
console.log(sq.name(), sq.area(), m.describe(sq));
sq.close();
console.log(m.shout((s) => s + "!", "hey"));
let t = `try ${m.try_twice(twice, 1)}`;
try {
    m.try_twice(twice, 4);
} catch (e) {
    t += ` ${e.code}`;
}
console.log(t);
n = m.opened_by((owner) => {
    const b = m.account.open(owner);
    b.deposit(7);
    return b;
});
console.log("opened", n);
console.log("closed", m.closed_accounts());
const d = m.doubler();
const hi = m.greeter();
console.log(d(21), hi("volt"));
d.close();
hi.close();
lists();
checks();
c.close();
