// flags: --leak-check
use std::io;
use std::html;
use std::json;
use std::string;
// std::html: text and attributes escaped, and templates rendered from JSON values: slots ({{x}},
// escaped; {{{x}}} as it is), loops ({{for p in pages}}), nested loops, if/else, and the errors for a
// slot the data doesn't have, a template that doesn't parse and a file that can't be read, each with
// the line and tag why() names

fn show(src: str, data: std::json::value&) -> void {
    val t = std::html::template::parse(src) catch |e| {
        std::println("parse: {}: {}", e, std::html::why());
        return;
    };
    var out: std::string = {};
    t.render(data, &out) catch |e| {
        std::println("render: {}: {}", e, std::html::why());
        return;
    };
    std::println("{}", out.as_str());
}

fn main() -> !void {
    std::println("{}", std::html::escaped("a < b && \"c\" > 'd'").as_str());
    val data = try std::json::parse("{\"title\": \"Fish & <Chips>\", \"body\": \"<b>bold</b>\", \"pages\": [{\"name\": \"one\", \"tags\": [\"a\", \"b\"]}, {\"name\": \"two\", \"tags\": []}], \"draft\": false, \"n\": 3}");
    show("<h1>{{title}}</h1>", &data);
    show("<div>{{{body}}}</div>", &data);
    show("<ul>{{for p in pages}}<li>{{p.name}}:{{for t in p.tags}} {{t}}{{end}}</li>{{end}}</ul>", &data);
    show("{{if draft}}draft{{else}}live{{end}} {{if pages}}some{{end}}{{if missing}}never{{end}}", &data);
    show("{{n}} pages", &data);
    show("<p>{{subtitle}}</p>", &data);
    show("{{for p in pages}}unclosed", &data);
    show("{{if}}x{{end}}", &data);
    show("{{end}}", &data);
    show("{{a b}}", &data);
    show("<ul>\n{{for p in pages}}\n<li>{{p.title}}</li>\n{{end}}\n</ul>", &data);
    show("{{for p in title}}{{end}}", &data);
    show("a\n{{{body}}\nb", &data);
    val none = std::html::template::read("/no/such/dir/page.html") catch |e| {
        std::println("read: {}: {}", e, std::html::why());
        return;
    };
}
// expect: a &lt; b &amp;&amp; &quot;c&quot; &gt; &#39;d&#39;
// expect: <h1>Fish &amp; &lt;Chips&gt;</h1>
// expect: <div><b>bold</b></div>
// expect: <ul><li>one: a b</li><li>two:</li></ul>
// expect: live some
// expect: 3 pages
// expect: render: MISSING: line 1: {{subtitle}}: no value
// expect: parse: SYNTAX: line 1: {{for p in pages}}: no {{end}} for it
// expect: parse: SYNTAX: line 1: {{if}}: not a path (names joined by dots)
// expect: parse: SYNTAX: line 1: {{end}}: nothing open for it
// expect: parse: SYNTAX: line 1: {{a b}}: not a path (names joined by dots)
// expect: render: MISSING: line 3: {{p.title}}: no value
// expect: render: MISSING: line 1: {{for p in title}}: no list
// expect: parse: SYNTAX: line 2: {{{: no }}} after it
// expect: read: READ: /no/such/dir/page.html: can't be read
