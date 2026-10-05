// json: generate a JSON array of n objects (nested arrays and objects, escaped strings, ints and
// decimals) as text, parse it into a tree, then walk the tree for counts and sums; C++ hand-writes a
// recursive-descent parser class into a std::variant tree (std::string, std::vector, members in
// order), numbers by std::from_chars, errors as exceptions, and walks with std::visit
#include <charconv>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <format>
#include <iterator>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <variant>
#include <vector>

static uint64_t x = 88172645463325252ULL;

static uint64_t next() {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

// ---------- the text ----------

static constexpr std::string_view WORDS[8] = {"alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"};
static constexpr std::string_view ESCAPES[5] = {"\\\"", "\\\\", "\\n", "\\t", "\\u00e9"};

// a string of 2 to 5 pieces, a quarter of them escapes
static void put_name(std::string &out) {
    out += '"';
    uint64_t pieces = 2 + next() % 4;
    for (uint64_t k = 0; k < pieces; k++) {
        if (next() % 4 == 0) out += ESCAPES[next() % 5];
        else out += WORDS[next() % 8];
    }
    out += '"';
}

static void put_object(std::string &out, long i) {
    out += "{\"id\":";
    out += std::to_string(i);
    out += ",\"name\":";
    put_name(out);
    long cents = next() % 1000000;
    std::format_to(std::back_inserter(out), ",\"score\":{}.{:02},\"tags\":[", cents / 100, cents % 100);
    uint64_t tags = next() % 5;
    for (uint64_t k = 0; k < tags; k++) {
        if (k > 0) out += ',';
        out += '"';
        out += WORDS[next() % 8];
        out += '"';
    }
    out += "],\"pos\":[";
    for (int k = 0; k < 3; k++) {
        if (k > 0) out += ',';
        out += std::to_string((long long)(next() % 2000001) - 1000000);
    }
    out += next() % 2 ? "],\"active\":true" : "],\"active\":false";
    out += ",\"meta\":{\"level\":";
    out += std::to_string(next() % 10);
    std::format_to(std::back_inserter(out), ",\"ratio\":0.{:03},\"note\":", next() % 1000);
    if (next() % 3 == 0) out += "null";
    else put_name(out);
    out += "}}";
}

// ---------- the tree ----------

struct json_value;
struct json_member;
using json_array = std::vector<json_value>;
using json_object = std::vector<json_member>; // members in order

struct json_value {
    std::variant<std::nullptr_t, bool, double, std::string, json_array, json_object> v;

    const json_value *get(std::string_view key) const;
};

struct json_member {
    std::string name;
    json_value item;
};

// an object's member called key, or nullptr
const json_value *json_value::get(std::string_view key) const {
    if (auto *members = std::get_if<json_object>(&v))
        for (auto &m : *members)
            if (m.name == key) return &m.item;
    return nullptr;
}

// ---------- parsing ----------

class parser {
    const char *p, *end;

    [[noreturn]] void fail() { throw std::runtime_error("not JSON"); }

    void skip_space() {
        while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
    }

    bool word(std::string_view w) {
        if (std::string_view(p, end - p).starts_with(w)) { p += w.size(); return true; }
        return false;
    }

    unsigned hex4(const char *s) {
        unsigned v;
        auto [q, ec] = std::from_chars(s, s + 4, v, 16);
        if (ec != std::errc() || q != s + 4) fail();
        return v;
    }

    static void put_utf8(std::string &o, unsigned cp) {
        if (cp < 0x80) o += char(cp);
        else if (cp < 0x800) { o += char(0xC0 | cp >> 6); o += char(0x80 | (cp & 0x3F)); }
        else if (cp < 0x10000) { o += char(0xE0 | cp >> 12); o += char(0x80 | ((cp >> 6) & 0x3F)); o += char(0x80 | (cp & 0x3F)); }
        else { o += char(0xF0 | cp >> 18); o += char(0x80 | ((cp >> 12) & 0x3F)); o += char(0x80 | ((cp >> 6) & 0x3F)); o += char(0x80 | (cp & 0x3F)); }
    }

    // the string literal at p (its opening quote), unescaped
    std::string string() {
        p++;
        std::string out;
        while (p < end) {
            char c = *p;
            if (c == '"') { p++; return out; }
            if ((unsigned char)c < 0x20) fail();
            if (c != '\\') { out += c; p++; continue; }
            if (end - p < 2) fail();
            char e = p[1];
            p += 2;
            switch (e) {
            case 'n': out += '\n'; break;
            case 't': out += '\t'; break;
            case 'r': out += '\r'; break;
            case 'b': out += '\b'; break;
            case 'f': out += '\f'; break;
            case '"': case '\\': case '/': out += e; break;
            case 'u': {
                if (end - p < 4) fail();
                unsigned cp = hex4(p);
                p += 4;
                // a surrogate pair is one code point
                if (cp >= 0xD800 && cp < 0xDC00 && end - p >= 6 && p[0] == '\\' && p[1] == 'u') {
                    unsigned lo = hex4(p + 2);
                    if (lo >= 0xDC00 && lo < 0xE000) { cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00); p += 6; }
                }
                put_utf8(out, cp);
                break;
            }
            default: fail();
            }
        }
        fail();
    }

    json_value value(int depth) {
        if (depth > 512) fail();
        skip_space();
        if (p >= end) fail();
        char c = *p;
        if (c == '[') {
            p++;
            json_array items;
            skip_space();
            if (p < end && *p == ']') { p++; return {std::move(items)}; }
            for (;;) {
                items.push_back(value(depth + 1));
                skip_space();
                if (p < end && *p == ',') p++;
                else if (p < end && *p == ']') { p++; return {std::move(items)}; }
                else fail();
            }
        }
        if (c == '{') {
            p++;
            json_object members;
            skip_space();
            if (p < end && *p == '}') { p++; return {std::move(members)}; }
            for (;;) {
                skip_space();
                if (p >= end || *p != '"') fail();
                std::string name = string();
                skip_space();
                if (p >= end || *p != ':') fail();
                p++;
                members.push_back({std::move(name), value(depth + 1)});
                skip_space();
                if (p < end && *p == ',') p++;
                else if (p < end && *p == '}') { p++; return {std::move(members)}; }
                else fail();
            }
        }
        if (c == '"') return {string()};
        if (word("true")) return {true};
        if (word("false")) return {false};
        if (word("null")) return {nullptr};
        double d;
        auto [q, ec] = std::from_chars(p, end, d);
        if (ec != std::errc()) fail();
        p = q;
        return {d};
    }

public:
    // the whole text as one value; whitespace around it is fine, anything else isn't
    static json_value parse(std::string_view text) {
        parser ps;
        ps.p = text.data();
        ps.end = text.data() + text.size();
        json_value v = ps.value(0);
        ps.skip_space();
        if (ps.p != ps.end) ps.fail();
        return v;
    }
};

// ---------- walking ----------

struct stats {
    long objects = 0, arrays = 0, strings = 0, numbers = 0, trues = 0, nulls = 0, string_bytes = 0;

    void operator()(std::nullptr_t) { nulls++; }
    void operator()(bool b) { trues += b; }
    void operator()(double) { numbers++; }
    void operator()(const std::string &s) { strings++; string_bytes += s.size(); }
    void operator()(const json_array &items) {
        arrays++;
        for (auto &item : items) std::visit(*this, item.v);
    }
    void operator()(const json_object &members) {
        objects++;
        for (auto &m : members) std::visit(*this, m.item.v);
    }
};

int main(int argc, char **argv) {
    long n = argc > 1 ? std::atol(argv[1]) : 400000;
    std::string text = "[";
    for (long i = 0; i < n; i++) {
        if (i > 0) text += ",\n";
        put_object(text, i);
    }
    text += "]\n";
    json_value doc = parser::parse(text);
    stats s;
    std::visit(s, doc.v);
    long long ids = 0, cents = 0;
    for (auto &item : std::get<json_array>(doc.v)) {
        if (auto id = item.get("id"); id && std::holds_alternative<double>(id->v)) ids += (long long)std::get<double>(id->v);
        if (auto score = item.get("score"); score && std::holds_alternative<double>(score->v)) cents += (long long)(std::get<double>(score->v) * 100.0 + 0.5);
    }
    std::printf("%zu bytes: %ld objects, %ld arrays, %ld strings, %ld numbers\n", text.size(), s.objects, s.arrays, s.strings, s.numbers);
    std::printf("%ld string bytes, %ld true, %ld null\n", s.string_bytes, s.trues, s.nulls);
    std::printf("%lld %lld\n", ids, cents);
}
