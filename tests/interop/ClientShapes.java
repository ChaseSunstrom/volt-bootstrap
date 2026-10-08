// Java calls shapelib (voltc bindings --lang java): a generic's instances, a struct held by a class
// with methods, owned values passed in, a Volt trait as a Java interface both ways, callbacks taking
// and giving text, handles and errors, closures given back, and lists as arrays
import java.lang.foreign.*;
import static java.lang.foreign.ValueLayout.*;

public class ClientShapes {
    // Java's own shape: Volt calls it through the trait's table, and closes one it was given
    static final class Circle implements shapelib.shape, AutoCloseable {
        double r;

        Circle(double r) {
            this.r = r;
        }

        public double area() {
            return 3 * r * r;
        }

        public String name() {
            return "circle";
        }

        public void grow(double by) {
            r += by;
        }

        public void close() {
            System.out.println("circle gone");
        }
    }

    static String fmt(double d) {
        return d == Math.rint(d) ? String.valueOf((long) d) : String.valueOf(d);
    }

    static int twice(int x) {
        if (x > 5) {
            throw shapelib.VoltException.of(shapelib.bank_error.OVERDRAWN);
        }
        return x * 2;
    }

    // what C and C++ don't print: an E!void callback, closures given back giving E!void and a str
    static void extras() {
        boolean ok = true;
        try {
            shapelib.checked(x -> {
                if (x <= 0) {
                    throw shapelib.VoltException.of(shapelib.bank_error.OVERDRAWN);
                }
            }, 1);
        } catch (shapelib.VoltException e) {
            ok = false;
        }
        String err = "";
        try {
            shapelib.checked(x -> {
                throw shapelib.VoltException.of(shapelib.bank_error.OVERDRAWN);
            }, 1);
        } catch (shapelib.bank_error e) {
            err = e.name;
        }
        System.out.println("checked " + ok + " " + err);
        try (var lim = shapelib.limiter()) {
            boolean under = true;
            try {
                lim.call(3);
            } catch (shapelib.VoltException e) {
                under = false;
            }
            String over = "";
            try {
                lim.call(12);
            } catch (shapelib.bank_error e) {
                over = e.name;
            }
            System.out.println("limit " + under + " " + over);
        }
        try (var sign = shapelib.labeler()) {
            System.out.println("sign " + sign.call(5) + " " + sign.call(-1));
        }
    }

    // lists (arrays both ways), arrays of text and handles, null for none
    static void lists() {
        var a = shapelib.account.open("ann");
        a.deposit(5);
        var b = shapelib.account.open("bobby");
        b.deposit(9);
        shapelib.account[] ab = {a, b};
        String[] os = shapelib.owners(ab);
        System.out.println("owners " + os.length + " " + os[0] + " " + os[1]);
        System.out.print("richest " + shapelib.richest(ab));
        System.out.println(" after " + a.get() + " " + b.get());
        var opened = shapelib.open_all(new String[] {"cy", "dee"});
        System.out.println("opened " + opened.length + " " + opened[1].owner());
        for (var x : opened) {
            x.close();
        }
        long[] sq = shapelib.squares_upto(4);
        System.out.println("squares " + sq.length + " " + sq[3] + " sum " + shapelib.sum_all(sq));
        String[] parts = {"a", "b", "c"};
        System.out.println("joined " + shapelib.joined(parts, "-") + " total " + shapelib.total_len(parts));
        System.out.println(shapelib.greeting("ann") + "; " + shapelib.greeting(null));
        String n1 = shapelib.nickname(a);
        String n2 = shapelib.nickname(b);
        System.out.println("nick " + (n1 != null ? 1 : 0) + " " + n1 + " " + (n2 != null ? 1 : 0));
        var c = shapelib.open_if("eve", true);
        var d = shapelib.open_if("x", false);
        System.out.println("open_if " + (c != null ? 1 : 0) + " " + (d == null ? 1 : 0));
        long c1 = shapelib.close_if(c);
        System.out.println("close_if " + c1 + " " + shapelib.close_if(null));
        System.out.println("close_all " + shapelib.close_all(ab));
        System.out.println("some " + shapelib.count_some(new Long[] {1L, null, 3L}));
        System.out.println("rows " + shapelib.total_rows(new long[][] {{1, 2}, {3}}));
        long[] rot = shapelib.rotated(new long[] {11, 12, 13});
        double[] sw = shapelib.swapped(new double[] {1.5, 2.5});
        byte[] bu = shapelib.bumped(new byte[] {1, 2, 3});
        System.out.println("arrays " + rot[0] + " " + rot[1] + " " + rot[2] + " " + sw[0] + " " + sw[1] + " " + bu[0] + " " + bu[1] + " " + bu[2]);
        System.out.println("lists closed " + shapelib.closed_accounts());
    }

    // an account a running call lent to Volt can't be closed or given away by a callback meanwhile
    // (it prints only what was wrongly accepted)
    static void inUse() {
        var a = shapelib.account.open("busy");
        try {
            shapelib.visit(a, x -> {
                a.close();
                return 0;
            });
            System.out.println("accepted: closing an account a call holds");
        } catch (IllegalStateException e) {
        }
        try {
            shapelib.visit(a, x -> shapelib.close_account(a));
            System.out.println("accepted: giving away an account a call holds");
        } catch (IllegalStateException e) {
        }
        try {
            shapelib.visit_over(new shapelib.account[] {a}, x -> {
                a.close();
                return 0;
            });
            System.out.println("accepted: closing an account a call holds in an array");
        } catch (IllegalStateException e) {
        }
        try {
            shapelib.lend_give(a, a);
            System.out.println("accepted: lending and giving one account in one call");
        } catch (IllegalStateException e) {
        }
        // a callback that throws leaves what the call lent as it was (closable after)
        try {
            shapelib.visit_then(x -> {
                throw new RuntimeException("thrown");
            }, a);
        } catch (RuntimeException e) {
        }
        a.close();
    }

    @SuppressWarnings("restricted")
    public static void main(String[] args) {
        extras();
        System.out.println("biggest " + shapelib.biggest_i32(new int[] {3, 9, 4}) + " " + fmt(shapelib.biggest_f64(new double[] {1.5, 0.5})));
        var a = shapelib.account.open("ann");
        a.deposit(250);
        a.rename("bea");
        long n = a.deposit(50);
        System.out.println("account " + a.owner() + " " + n);
        n = shapelib.visit(a, x -> x.deposit(1));
        System.out.println("visit " + n + " get " + a.get());
        n = shapelib.close_account(a);
        System.out.println("closed " + n + " " + shapelib.closed_accounts());
        var c = new Circle(1);
        System.out.println(shapelib.describe(c));
        System.out.println("grown " + fmt(shapelib.grow_twice(new Circle(1))));
        try (var sq = shapelib.make_square(2)) {
            sq.grow(1);
            String nm = sq.name();
            double area = sq.area();
            System.out.println(nm + " " + fmt(area) + " " + shapelib.describe(sq));
        }
        System.out.println(shapelib.shout(s -> s + "!", "hey"));
        System.out.print("try " + shapelib.try_twice(ClientShapes::twice, 1));
        try {
            shapelib.try_twice(ClientShapes::twice, 4);
        } catch (shapelib.bank_error e) {
            System.out.println(" " + e.name);
        }
        n = shapelib.opened_by(owner -> {
            var b = shapelib.account.open(owner);
            b.deposit(7);
            return b;
        });
        System.out.println("opened " + n);
        System.out.println("closed " + shapelib.closed_accounts());
        try (var d = shapelib.doubler(); var hi = shapelib.greeter()) {
            System.out.println(d.call(21) + " " + hi.call("volt"));
        }
        lists();
        inUse();
        c.close();
        // what the library still holds (0: everything was freed)
        var live = SymbolLookup.libraryLookup(System.getProperty("volt.shapelib.lib", System.mapLibraryName("shapelib")), Arena.global()).find("volt_live_allocs").orElseThrow();
        System.err.println("volt live: " + live.reinterpret(8).get(JAVA_LONG, 0));
    }
}
