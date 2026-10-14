// an internal field of a package's struct is the package's own: no reading, writing or naming it
// in a literal from outside (each fn below is checked on its own, so each reports its error)
fn read_it() -> void {
    val a = vis::make_account(1);
    val s = a.secret;
}

fn write_it() -> void {
    var a = vis::make_account(1);
    a.secret = 3;
}

fn literal_it() -> void {
    val a: vis::account = { id: 1, secret: 2 };
}

fn main() -> void {}
// error: field 'secret' is internal to package vis
// flags: --pkg vis=tests/pkgs/vis
