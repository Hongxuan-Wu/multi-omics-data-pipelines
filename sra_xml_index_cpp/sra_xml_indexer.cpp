#include <algorithm>
#include <chrono>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace fs = std::filesystem;

namespace {

constexpr uint64_t kFnvOffset = 1469598103934665603ULL;
constexpr uint64_t kFnvPrime = 1099511628211ULL;
constexpr size_t kDesignDescriptionLimit = 2000;
constexpr size_t kValueLimit = 2000;
constexpr size_t kExampleLimit = 500;
constexpr uint64_t kDefaultMaxXmlBytes = 100ULL * 1024ULL * 1024ULL;

uint64_t stable_file_id(const std::string& directory_accession, const std::string& file_name) {
    std::string key = directory_accession + "/" + file_name;
    uint64_t h = kFnvOffset;
    for (unsigned char c : key) {
        h ^= static_cast<uint64_t>(c);
        h *= kFnvPrime;
    }
    return h & ((1ULL << 63) - 1ULL);
}

std::string clean_text(std::string_view input) {
    std::string out;
    out.reserve(input.size());
    bool in_space = false;
    for (char c : input) {
        unsigned char uc = static_cast<unsigned char>(c);
        if (std::isspace(uc)) {
            if (!out.empty()) in_space = true;
            continue;
        }
        if (in_space && !out.empty()) out.push_back(' ');
        in_space = false;
        out.push_back(c == '\t' ? ' ' : c);
    }
    return out;
}

std::string xml_decode(std::string_view input) {
    std::string out;
    out.reserve(input.size());
    for (size_t i = 0; i < input.size(); ++i) {
        if (input[i] == '&') {
            if (input.substr(i, 5) == "&amp;") {
                out.push_back('&');
                i += 4;
            } else if (input.substr(i, 4) == "&lt;") {
                out.push_back('<');
                i += 3;
            } else if (input.substr(i, 4) == "&gt;") {
                out.push_back('>');
                i += 3;
            } else if (input.substr(i, 6) == "&quot;") {
                out.push_back('"');
                i += 5;
            } else if (input.substr(i, 6) == "&apos;") {
                out.push_back('\'');
                i += 5;
            } else {
                out.push_back(input[i]);
            }
        } else {
            out.push_back(input[i]);
        }
    }
    return out;
}

std::string tsv(std::string_view input) {
    std::string decoded = xml_decode(input);
    std::string out = clean_text(decoded);
    for (char& c : out) {
        if (c == '\t' || c == '\n' || c == '\r') c = ' ';
    }
    return out;
}

std::pair<std::string, bool> truncate_to(std::string_view input, size_t limit) {
    std::string cleaned = clean_text(input);
    if (cleaned.size() > limit) return {cleaned.substr(0, limit), true};
    return {cleaned, false};
}

std::string attr(std::string_view open_tag, const std::string& name) {
    std::string key = name + "=";
    size_t pos = open_tag.find(key);
    if (pos == std::string_view::npos) {
        key = name + " =";
        pos = open_tag.find(key);
    }
    if (pos == std::string_view::npos) return "";
    pos = open_tag.find_first_of("\"'", pos);
    if (pos == std::string_view::npos) return "";
    char quote = open_tag[pos++];
    size_t end = open_tag.find(quote, pos);
    if (end == std::string_view::npos) return "";
    return tsv(open_tag.substr(pos, end - pos));
}

bool starts_with_tag(std::string_view xml, size_t pos, const std::string& tag) {
    if (pos + tag.size() + 1 >= xml.size()) return false;
    if (xml[pos] != '<') return false;
    if (xml.compare(pos + 1, tag.size(), tag) != 0) return false;
    char next = xml[pos + 1 + tag.size()];
    return next == '>' || std::isspace(static_cast<unsigned char>(next)) || next == '/';
}

std::string first_tag_text(std::string_view xml, const std::string& tag) {
    size_t pos = 0;
    while ((pos = xml.find("<" + tag, pos)) != std::string_view::npos) {
        if (!starts_with_tag(xml, pos, tag)) {
            pos += tag.size() + 1;
            continue;
        }
        size_t open_end = xml.find('>', pos);
        if (open_end == std::string_view::npos) return "";
        std::string close = "</" + tag + ">";
        size_t close_pos = xml.find(close, open_end + 1);
        if (close_pos == std::string_view::npos) return "";
        return tsv(xml.substr(open_end + 1, close_pos - open_end - 1));
    }
    return "";
}

std::string first_open_tag(std::string_view xml, const std::string& tag) {
    size_t pos = 0;
    while ((pos = xml.find("<" + tag, pos)) != std::string_view::npos) {
        if (!starts_with_tag(xml, pos, tag)) {
            pos += tag.size() + 1;
            continue;
        }
        size_t open_end = xml.find('>', pos);
        if (open_end == std::string_view::npos) return "";
        return std::string(xml.substr(pos, open_end - pos + 1));
    }
    return "";
}

std::string external_id(std::string_view xml, const std::string& ns) {
    size_t pos = 0;
    while ((pos = xml.find("<EXTERNAL_ID", pos)) != std::string_view::npos) {
        size_t open_end = xml.find('>', pos);
        if (open_end == std::string_view::npos) return "";
        std::string open(xml.substr(pos, open_end - pos + 1));
        if (attr(open, "namespace") == ns) {
            size_t close_pos = xml.find("</EXTERNAL_ID>", open_end + 1);
            if (close_pos == std::string_view::npos) return "";
            return tsv(xml.substr(open_end + 1, close_pos - open_end - 1));
        }
        pos = open_end + 1;
    }
    return "";
}

std::string xref_label_for_db(std::string_view xml, const std::string& db_name) {
    size_t pos = 0;
    while ((pos = xml.find("<XREF_LINK", pos)) != std::string_view::npos) {
        size_t open_end = xml.find('>', pos);
        size_t close_pos = xml.find("</XREF_LINK>", open_end == std::string_view::npos ? pos : open_end + 1);
        if (open_end == std::string_view::npos || close_pos == std::string_view::npos) return "";
        std::string_view block_view = xml.substr(open_end + 1, close_pos - open_end - 1);
        std::string block(block_view);
        std::string db = first_tag_text(block, "DB");
        if (db == db_name || db == "bioproject") {
            std::string label = first_tag_text(block, "LABEL");
            if (!label.empty()) return label;
            return first_tag_text(block, "ID");
        }
        pos = close_pos + 12;
    }
    return "";
}

std::string xml_kind_from_name(const std::string& name) {
    auto ends = [&](const std::string& suffix) {
        return name.size() >= suffix.size() && name.compare(name.size() - suffix.size(), suffix.size(), suffix) == 0;
    };
    if (ends(".run.xml")) return "run";
    if (ends(".experiment.xml")) return "experiment";
    if (ends(".sample.xml")) return "sample";
    if (ends(".study.xml")) return "study";
    if (ends(".submission.xml")) return "submission";
    if (ends(".analysis.xml")) return "analysis";
    return "unknown";
}

std::string read_file(const fs::path& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("cannot open " + path.string());
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

std::vector<std::string> blocks(const std::string& xml, const std::string& tag) {
    std::vector<std::string> out;
    size_t pos = 0;
    std::string close = "</" + tag + ">";
    while ((pos = xml.find("<" + tag, pos)) != std::string::npos) {
        if (!starts_with_tag(xml, pos, tag)) {
            pos += tag.size() + 1;
            continue;
        }
        size_t open_end = xml.find('>', pos);
        if (open_end == std::string::npos) break;
        size_t close_pos = xml.find(close, open_end + 1);
        if (close_pos == std::string::npos) break;
        close_pos += close.size();
        out.emplace_back(xml.substr(pos, close_pos - pos));
        pos = close_pos;
    }
    return out;
}

std::string accession_of(const std::string& block, const std::string& tag) {
    std::string open = first_open_tag(block, tag);
    std::string accession = attr(open, "accession");
    if (!accession.empty()) return accession;
    return first_tag_text(block, "PRIMARY_ID");
}

struct Writers {
    std::ofstream directory_index;
    std::ofstream file_index;
    std::ofstream entity_index;
    std::ofstream relation_index;
    std::ofstream run_core;
    std::ofstream experiment_core;
    std::ofstream sample_core;
    std::ofstream sample_attribute_core;
    std::ofstream study_core;
    std::ofstream submission_core;
    std::ofstream analysis_core;
    std::ofstream selected_fields;
    std::ofstream path_inventory;
    std::ofstream slow_directory_log;
};

struct InventoryRow {
    uint64_t occurrence_count = 0;
    uint64_t non_empty_count = 0;
    std::string example_value;
    bool value_truncated = false;
};

std::string inventory_key(const std::string& xml_kind, const std::string& entity_type, const std::string& path,
                          const std::string& attr_name, const std::string& value_kind) {
    return xml_kind + "\t" + entity_type + "\t" + path + "\t" + attr_name + "\t" + value_kind;
}

void add_inventory(std::unordered_map<std::string, InventoryRow>& inv, const std::string& xml_kind,
                   const std::string& entity_type, const std::string& path, const std::string& attr_name,
                   const std::string& value_kind, const std::string& value) {
    std::string key = inventory_key(xml_kind, entity_type, path, attr_name, value_kind);
    auto& row = inv[key];
    ++row.occurrence_count;
    if (!value.empty()) ++row.non_empty_count;
    if (row.example_value.empty() && !value.empty()) {
        auto [example, truncated] = truncate_to(value, kExampleLimit);
        row.example_value = example;
        row.value_truncated = truncated;
    }
}

std::vector<std::string> split_key(const std::string& key) {
    std::vector<std::string> out;
    size_t start = 0;
    for (size_t i = 0; i <= key.size(); ++i) {
        if (i == key.size() || key[i] == '\t') {
            out.push_back(key.substr(start, i - start));
            start = i + 1;
        }
    }
    return out;
}

void write_inventory(std::ofstream& out, const std::unordered_map<std::string, InventoryRow>& inv) {
    std::vector<std::string> keys;
    keys.reserve(inv.size());
    for (const auto& kv : inv) keys.push_back(kv.first);
    std::sort(keys.begin(), keys.end());
    for (const auto& key : keys) {
        auto parts = split_key(key);
        const auto& row = inv.at(key);
        if (parts.size() != 5) continue;
        out << parts[0] << '\t' << parts[1] << '\t' << parts[2] << '\t' << parts[3] << '\t' << parts[4] << '\t'
            << row.occurrence_count << '\t' << row.non_empty_count << '\t' << tsv(row.example_value) << '\t'
            << (row.value_truncated ? "true" : "false") << '\n';
    }
}

void open_with_header(std::ofstream& out, const fs::path& path, const std::string& header) {
    fs::create_directories(path.parent_path());
    out.open(path);
    if (!out) throw std::runtime_error("cannot write " + path.string());
    out << header << "\n";
}

Writers make_writers(const fs::path& out) {
    Writers w;
    open_with_header(w.directory_index, out / "directory_index.tsv",
        "directory_accession\tprefix\tdirectory_path\tfile_count\txml_file_count\ttotal_xml_bytes\thas_run_xml\thas_experiment_xml\thas_sample_xml\thas_study_xml\thas_submission_xml\thas_analysis_xml\tscan_status\terror_message");
    open_with_header(w.file_index, out / "file_index.tsv",
        "file_id\tdirectory_accession\txml_kind\tfile_name\tfile_path\tfile_size\tmtime\tparse_status\troot_tag\tentity_count\terror_type\terror_message");
    open_with_header(w.entity_index, out / "entity_index.tsv",
        "entity_accession\tentity_type\tdirectory_accession\tfile_id\tentity_ordinal\talias\tprimary_id\tsubmitter_id");
    open_with_header(w.relation_index, out / "relation_index.tsv",
        "src_accession\tsrc_type\trelation_type\tdst_accession\tdst_type\tdirectory_accession\tfile_id");
    open_with_header(w.run_core, out / "core" / "run_core.tsv",
        "run_accession\talias\texperiment_accession\tdirectory_accession\tfile_id");
    open_with_header(w.experiment_core, out / "core" / "experiment_core.tsv",
        "experiment_accession\talias\ttitle\tstudy_accession\tsample_accession\tlibrary_strategy\tlibrary_source\tlibrary_selection\tlibrary_layout\tplatform\tinstrument_model\tdesign_description\tdesign_description_truncated\tcenter_name\tdirectory_accession\tfile_id");
    open_with_header(w.sample_core, out / "core" / "sample_core.tsv",
        "sample_accession\talias\tbio_sample_id\ttaxon_id\tscientific_name\tbioproject_id\tdirectory_accession\tfile_id");
    open_with_header(w.sample_attribute_core, out / "core" / "sample_attribute_core.tsv",
        "sample_accession\tbio_sample_id\ttag\tvalue\tdirectory_accession\tfile_id\tattribute_ordinal\tvalue_truncated");
    open_with_header(w.study_core, out / "core" / "study_core.tsv",
        "study_accession\talias\tbioproject_id\tstudy_title\tstudy_abstract\tstudy_type\texisting_study_type\tdirectory_accession\tfile_id");
    open_with_header(w.submission_core, out / "core" / "submission_core.tsv",
        "submission_accession\talias\tcenter_name\tlab_name\tdirectory_accession\tfile_id");
    open_with_header(w.analysis_core, out / "core" / "analysis_core.tsv",
        "analysis_accession\talias\tcenter_name\ttitle\tdirectory_accession\tfile_id");
    open_with_header(w.selected_fields, out / "fields" / "xml_field_long_selected.tsv",
        "directory_accession\tentity_accession\tentity_type\txml_kind\tfile_id\tentity_ordinal\tfield_path\tfield_name\tattribute_name\tvalue\tvalue_kind\tvalue_truncated");
    open_with_header(w.path_inventory, out / "inventory" / "xml_path_inventory.tsv",
        "xml_kind\tentity_type\tfield_path\tattribute_name\tvalue_kind\toccurrence_count\tnon_empty_count\texample_value\tvalue_truncated");
    open_with_header(w.slow_directory_log, out / "slow_directory_log.tsv",
        "directory_index\tdirectory_accession\txml_file_count\ttotal_xml_bytes\telapsed_seconds");
    return w;
}

void relation(std::ofstream& out, const std::string& src, const std::string& src_type, const std::string& rel,
              const std::string& dst, const std::string& dst_type, const std::string& dir, uint64_t file_id) {
    if (src.empty() || dst.empty()) return;
    out << src << '\t' << src_type << '\t' << rel << '\t' << dst << '\t' << dst_type << '\t' << dir << '\t' << file_id << '\n';
}

void selected(std::ofstream& out, const std::string& dir, const std::string& acc, const std::string& type,
              const std::string& kind, uint64_t file_id, int ordinal, const std::string& path,
              const std::string& name, const std::string& value, const std::string& attr_name = "", const std::string& value_kind = "text") {
    if (value.empty()) return;
    auto [truncated, was_truncated] = truncate_to(value, kValueLimit);
    out << dir << '\t' << acc << '\t' << type << '\t' << kind << '\t' << file_id << '\t' << ordinal << '\t'
        << path << '\t' << name << '\t' << attr_name << '\t' << tsv(truncated) << '\t' << value_kind << '\t'
        << (was_truncated ? "true" : "false") << '\n';
}

std::string child_attr_accession(const std::string& block, const std::string& tag) {
    return attr(first_open_tag(block, tag), "accession");
}

std::string tag_name_at(std::string_view xml, size_t pos) {
    if (pos >= xml.size() || xml[pos] != '<') return "";
    size_t i = pos + 1;
    if (i < xml.size() && xml[i] == '/') ++i;
    size_t start = i;
    while (i < xml.size()) {
        char c = xml[i];
        if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '_' || c == '-' || c == ':')) break;
        ++i;
    }
    return std::string(xml.substr(start, i - start));
}

std::unordered_map<std::string, std::string> parse_attrs(std::string_view open_tag) {
    std::unordered_map<std::string, std::string> attrs;
    size_t i = 0;
    while (i < open_tag.size()) {
        while (i < open_tag.size() && !std::isalpha(static_cast<unsigned char>(open_tag[i]))) ++i;
        size_t name_start = i;
        while (i < open_tag.size() && (std::isalnum(static_cast<unsigned char>(open_tag[i])) || open_tag[i] == '_' || open_tag[i] == '-' || open_tag[i] == ':')) ++i;
        if (i >= open_tag.size()) break;
        std::string name(open_tag.substr(name_start, i - name_start));
        while (i < open_tag.size() && std::isspace(static_cast<unsigned char>(open_tag[i]))) ++i;
        if (i >= open_tag.size() || open_tag[i] != '=') continue;
        ++i;
        while (i < open_tag.size() && std::isspace(static_cast<unsigned char>(open_tag[i]))) ++i;
        if (i >= open_tag.size() || (open_tag[i] != '"' && open_tag[i] != '\'')) continue;
        char quote = open_tag[i++];
        size_t value_start = i;
        size_t value_end = open_tag.find(quote, i);
        if (value_end == std::string_view::npos) break;
        attrs[name] = tsv(open_tag.substr(value_start, value_end - value_start));
        i = value_end + 1;
    }
    return attrs;
}

void collect_inventory_for_block(std::string_view block, const std::string& xml_kind, const std::string& entity_type,
                                 std::unordered_map<std::string, InventoryRow>& inv) {
    std::vector<std::string> stack;
    size_t pos = 0;
    while ((pos = block.find('<', pos)) != std::string_view::npos) {
        if (pos + 1 >= block.size()) break;
        if (block[pos + 1] == '?' || block[pos + 1] == '!') {
            ++pos;
            continue;
        }
        bool closing = block[pos + 1] == '/';
        size_t end = block.find('>', pos);
        if (end == std::string_view::npos) break;
        std::string name = tag_name_at(block, pos);
        if (name.empty()) {
            pos = end + 1;
            continue;
        }
        if (closing) {
            if (!stack.empty()) stack.pop_back();
            pos = end + 1;
            continue;
        }
        stack.push_back(name);
        std::string path;
        for (size_t i = 0; i < stack.size(); ++i) {
            if (i) path.push_back('/');
            path += stack[i];
        }
        std::string open(block.substr(pos, end - pos + 1));
        for (const auto& kv : parse_attrs(open)) {
            add_inventory(inv, xml_kind, entity_type, path, kv.first, "attribute", kv.second);
        }
        size_t next_open = block.find('<', end + 1);
        std::string value;
        if (next_open != std::string_view::npos && next_open > end + 1) {
            value = tsv(block.substr(end + 1, next_open - end - 1));
        }
        if (!value.empty()) add_inventory(inv, xml_kind, entity_type, path, "", "text", value);
        bool self_closing = end > pos && block[end - 1] == '/';
        if (self_closing) {
            if (!stack.empty()) stack.pop_back();
        }
        pos = end + 1;
    }
}

std::string platform_child(const std::string& block) {
    size_t p = block.find("<PLATFORM");
    if (p == std::string::npos) return "";
    size_t open_end = block.find('>', p);
    size_t close = block.find("</PLATFORM>", open_end == std::string::npos ? p : open_end + 1);
    if (open_end == std::string::npos || close == std::string::npos) return "";
    std::string_view inside(block.data() + open_end + 1, close - open_end - 1);
    size_t child = inside.find('<');
    while (child != std::string_view::npos && child + 1 < inside.size() && (inside[child + 1] == '!' || inside[child + 1] == '?')) {
        child = inside.find('<', child + 1);
    }
    if (child == std::string_view::npos || child + 1 < inside.size() && inside[child + 1] == '/') return "";
    return tag_name_at(inside, child);
}

void parse_xml_file(const fs::path& path, const std::string& dir_acc, Writers& w,
                    std::unordered_map<std::string, InventoryRow>& inventory) {
    const std::string file_name = path.filename().string();
    const std::string kind = xml_kind_from_name(file_name);
    const uint64_t file_id = stable_file_id(dir_acc, file_name);
    const auto stat_size = fs::file_size(path);
    const auto mtime = fs::last_write_time(path).time_since_epoch().count();
    std::string xml;
    std::string root_tag;
    std::string parse_status = "ok";
    std::string error_type = "none";
    std::string error_message;
    uint64_t entity_count = 0;
    try {
        if (stat_size > kDefaultMaxXmlBytes) {
            parse_status = "oversized_xml";
            error_type = "oversized_xml";
            error_message = "file exceeds max xml bytes";
        } else {
            xml = read_file(path);
            size_t root_pos = xml.find('<');
            while (root_pos != std::string::npos && root_pos + 1 < xml.size() && (xml[root_pos + 1] == '?' || xml[root_pos + 1] == '!')) {
                root_pos = xml.find('<', root_pos + 1);
            }
            if (root_pos != std::string::npos) {
                size_t name_start = root_pos + 1;
                size_t name_end = name_start;
                while (name_end < xml.size() && (std::isalpha(static_cast<unsigned char>(xml[name_end])) || xml[name_end] == '_')) ++name_end;
                root_tag = xml.substr(name_start, name_end - name_start);
            } else {
                parse_status = "unsupported_root";
                error_type = "unexpected_root";
            }
        }
    } catch (const std::exception& e) {
        parse_status = "io_error";
        error_type = "io";
        error_message = e.what();
    }

    auto emit_entity = [&](const std::string& acc, const std::string& type, int ordinal, const std::string& block, const std::string& tag) {
        if (acc.empty()) return;
        ++entity_count;
        std::string open = first_open_tag(block, tag);
        w.entity_index << acc << '\t' << type << '\t' << dir_acc << '\t' << file_id << '\t' << ordinal << '\t'
                       << attr(open, "alias") << '\t' << first_tag_text(block, "PRIMARY_ID") << '\t'
                       << first_tag_text(block, "SUBMITTER_ID") << '\n';
    };

    if (parse_status == "ok") {
        int ord = 0;
        for (const auto& block : blocks(xml, "RUN")) {
            ++ord;
            std::string acc = accession_of(block, "RUN");
            std::string open = first_open_tag(block, "RUN");
            std::string exp = child_attr_accession(block, "EXPERIMENT_REF");
            emit_entity(acc, "RUN", ord, block, "RUN");
            collect_inventory_for_block(block, kind, "RUN", inventory);
            relation(w.relation_index, acc, "RUN", "RUN_TO_EXPERIMENT", exp, "EXPERIMENT", dir_acc, file_id);
            w.run_core << acc << '\t' << attr(open, "alias") << '\t' << exp << '\t' << dir_acc << '\t' << file_id << '\n';
        }
        ord = 0;
        for (const auto& block : blocks(xml, "EXPERIMENT")) {
            ++ord;
            std::string acc = accession_of(block, "EXPERIMENT");
            std::string open = first_open_tag(block, "EXPERIMENT");
            std::string study = child_attr_accession(block, "STUDY_REF");
            std::string sample = child_attr_accession(block, "SAMPLE_DESCRIPTOR");
            std::string platform = attr(first_open_tag(block, "ILLUMINA"), "instrument_model");
            if (platform.empty()) platform = first_tag_text(block, "INSTRUMENT_MODEL");
            std::string platform_tag = platform_child(block);
            std::string design = first_tag_text(block, "DESIGN_DESCRIPTION");
            auto [design_trunc, design_was_trunc] = truncate_to(design, kDesignDescriptionLimit);
            emit_entity(acc, "EXPERIMENT", ord, block, "EXPERIMENT");
            collect_inventory_for_block(block, kind, "EXPERIMENT", inventory);
            relation(w.relation_index, acc, "EXPERIMENT", "EXPERIMENT_TO_SAMPLE", sample, "SAMPLE", dir_acc, file_id);
            relation(w.relation_index, acc, "EXPERIMENT", "EXPERIMENT_TO_STUDY", study, "STUDY", dir_acc, file_id);
            w.experiment_core << acc << '\t' << attr(open, "alias") << '\t' << first_tag_text(block, "TITLE") << '\t'
                              << study << '\t' << sample << '\t' << first_tag_text(block, "LIBRARY_STRATEGY") << '\t'
                              << first_tag_text(block, "LIBRARY_SOURCE") << '\t' << first_tag_text(block, "LIBRARY_SELECTION") << '\t'
                              << (block.find("<PAIRED") != std::string::npos ? "PAIRED" : (block.find("<SINGLE") != std::string::npos ? "SINGLE" : "")) << '\t'
                              << platform_tag << '\t'
                              << platform << '\t' << tsv(design_trunc) << '\t' << (design_was_trunc ? "true" : "false") << '\t'
                              << attr(open, "center_name") << '\t' << dir_acc << '\t' << file_id << '\n';
            selected(w.selected_fields, dir_acc, acc, "EXPERIMENT", kind, file_id, ord, "EXPERIMENT/TITLE", "TITLE", first_tag_text(block, "TITLE"));
            selected(w.selected_fields, dir_acc, acc, "EXPERIMENT", kind, file_id, ord, "EXPERIMENT/DESIGN/DESIGN_DESCRIPTION", "DESIGN_DESCRIPTION", design);
            selected(w.selected_fields, dir_acc, acc, "EXPERIMENT", kind, file_id, ord, "EXPERIMENT/PLATFORM", "PLATFORM", platform_tag);
            selected(w.selected_fields, dir_acc, acc, "EXPERIMENT", kind, file_id, ord, "EXPERIMENT/PLATFORM/INSTRUMENT_MODEL", "INSTRUMENT_MODEL", platform);
        }
        ord = 0;
        for (const auto& block : blocks(xml, "SAMPLE")) {
            ++ord;
            std::string acc = accession_of(block, "SAMPLE");
            std::string open = first_open_tag(block, "SAMPLE");
            std::string biosample = external_id(block, "BioSample");
            std::string bioproject = xref_label_for_db(block, "bioproject");
            std::string taxon = first_tag_text(block, "TAXON_ID");
            emit_entity(acc, "SAMPLE", ord, block, "SAMPLE");
            collect_inventory_for_block(block, kind, "SAMPLE", inventory);
            relation(w.relation_index, acc, "SAMPLE", "SAMPLE_TO_BIOSAMPLE", biosample, "BioSample", dir_acc, file_id);
            relation(w.relation_index, acc, "SAMPLE", "SAMPLE_TO_TAXON", taxon, "Taxon", dir_acc, file_id);
            if (!bioproject.empty()) relation(w.relation_index, acc, "SAMPLE", "SAMPLE_XREF_bioproject", bioproject, "BioProject", dir_acc, file_id);
            w.sample_core << acc << '\t' << attr(open, "alias") << '\t' << biosample << '\t' << taxon << '\t'
                          << first_tag_text(block, "SCIENTIFIC_NAME") << '\t' << bioproject << '\t' << dir_acc << '\t' << file_id << '\n';
            int aord = 0;
            selected(w.selected_fields, dir_acc, acc, "SAMPLE", kind, file_id, ord, "SAMPLE/IDENTIFIERS/EXTERNAL_ID[@namespace=BioSample]", "BioSample", biosample);
            selected(w.selected_fields, dir_acc, acc, "SAMPLE", kind, file_id, ord, "SAMPLE/SAMPLE_NAME/TAXON_ID", "TAXON_ID", taxon);
            selected(w.selected_fields, dir_acc, acc, "SAMPLE", kind, file_id, ord, "SAMPLE/SAMPLE_NAME/SCIENTIFIC_NAME", "SCIENTIFIC_NAME", first_tag_text(block, "SCIENTIFIC_NAME"));
            selected(w.selected_fields, dir_acc, acc, "SAMPLE", kind, file_id, ord, "SAMPLE/SAMPLE_LINKS/XREF_LINK[@DB=bioproject]", "BioProject", bioproject);
            for (const auto& ablock : blocks(block, "SAMPLE_ATTRIBUTE")) {
                ++aord;
                auto [val, trunc] = truncate_to(first_tag_text(ablock, "VALUE"), kValueLimit);
                w.sample_attribute_core << acc << '\t' << biosample << '\t' << first_tag_text(ablock, "TAG") << '\t'
                                        << tsv(val) << '\t' << dir_acc << '\t' << file_id << '\t' << aord << '\t'
                                        << (trunc ? "true" : "false") << '\n';
                selected(w.selected_fields, dir_acc, acc, "SAMPLE", kind, file_id, ord, "SAMPLE/SAMPLE_ATTRIBUTES/SAMPLE_ATTRIBUTE/TAG", "TAG", first_tag_text(ablock, "TAG"));
                selected(w.selected_fields, dir_acc, acc, "SAMPLE", kind, file_id, ord, "SAMPLE/SAMPLE_ATTRIBUTES/SAMPLE_ATTRIBUTE/VALUE", "VALUE", val);
            }
        }
        ord = 0;
        for (const auto& block : blocks(xml, "STUDY")) {
            ++ord;
            std::string acc = accession_of(block, "STUDY");
            std::string open = first_open_tag(block, "STUDY");
            std::string bp = external_id(block, "BioProject");
            std::string st_open = first_open_tag(block, "STUDY_TYPE");
            std::string existing_study_type = attr(st_open, "existing_study_type");
            std::string study_type = first_tag_text(block, "STUDY_TYPE");
            if (study_type.empty()) study_type = existing_study_type;
            emit_entity(acc, "STUDY", ord, block, "STUDY");
            collect_inventory_for_block(block, kind, "STUDY", inventory);
            relation(w.relation_index, acc, "STUDY", "STUDY_TO_BIOPROJECT", bp, "BioProject", dir_acc, file_id);
            w.study_core << acc << '\t' << attr(open, "alias") << '\t' << bp << '\t' << first_tag_text(block, "STUDY_TITLE") << '\t'
                         << first_tag_text(block, "STUDY_ABSTRACT") << '\t' << study_type << '\t'
                         << existing_study_type << '\t' << dir_acc << '\t' << file_id << '\n';
            selected(w.selected_fields, dir_acc, acc, "STUDY", kind, file_id, ord, "STUDY/DESCRIPTOR/STUDY_TITLE", "STUDY_TITLE", first_tag_text(block, "STUDY_TITLE"));
            selected(w.selected_fields, dir_acc, acc, "STUDY", kind, file_id, ord, "STUDY/DESCRIPTOR/STUDY_ABSTRACT", "STUDY_ABSTRACT", first_tag_text(block, "STUDY_ABSTRACT"));
            selected(w.selected_fields, dir_acc, acc, "STUDY", kind, file_id, ord, "STUDY/DESCRIPTOR/STUDY_TYPE", "STUDY_TYPE", study_type);
            selected(w.selected_fields, dir_acc, acc, "STUDY", kind, file_id, ord, "STUDY/DESCRIPTOR/STUDY_TYPE", "STUDY_TYPE", existing_study_type, "existing_study_type", "attribute");
            selected(w.selected_fields, dir_acc, acc, "STUDY", kind, file_id, ord, "STUDY/IDENTIFIERS/EXTERNAL_ID[@namespace=BioProject]", "BioProject", bp);
        }
        if (kind == "submission" || root_tag == "SUBMISSION") {
            std::string open = first_open_tag(xml, "SUBMISSION");
            std::string acc = attr(open, "accession");
            if (acc.empty()) acc = dir_acc;
            emit_entity(acc, "SUBMISSION", 1, xml, "SUBMISSION");
            collect_inventory_for_block(xml, kind, "SUBMISSION", inventory);
            w.submission_core << acc << '\t' << attr(open, "alias") << '\t' << attr(open, "center_name") << '\t'
                              << attr(open, "lab_name") << '\t' << dir_acc << '\t' << file_id << '\n';
            selected(w.selected_fields, dir_acc, acc, "SUBMISSION", kind, file_id, 1, "SUBMISSION", "CENTER_NAME", attr(open, "center_name"), "center_name", "attribute");
            selected(w.selected_fields, dir_acc, acc, "SUBMISSION", kind, file_id, 1, "SUBMISSION", "LAB_NAME", attr(open, "lab_name"), "lab_name", "attribute");
        }
        ord = 0;
        for (const auto& block : blocks(xml, "ANALYSIS")) {
            ++ord;
            std::string acc = accession_of(block, "ANALYSIS");
            std::string open = first_open_tag(block, "ANALYSIS");
            emit_entity(acc, "ANALYSIS", ord, block, "ANALYSIS");
            collect_inventory_for_block(block, kind, "ANALYSIS", inventory);
            w.analysis_core << acc << '\t' << attr(open, "alias") << '\t' << attr(open, "center_name") << '\t'
                            << first_tag_text(block, "TITLE") << '\t' << dir_acc << '\t' << file_id << '\n';
        }
    }

    w.file_index << file_id << '\t' << dir_acc << '\t' << kind << '\t' << file_name << '\t' << path.string() << '\t'
                 << stat_size << '\t' << mtime << '\t' << parse_status << '\t' << root_tag << '\t' << entity_count << '\t'
                 << error_type << '\t' << tsv(error_message) << '\n';
}

bool load_next_manifest_path(std::ifstream& in, fs::path& path) {
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) continue;
        path = fs::path(line);
        return true;
    }
    return false;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 4) {
        std::cerr << "Usage: " << argv[0] << " <root_or_manifest> <out_dir> <limit_dirs> [start_dirs]\n";
        return 2;
    }
    fs::path input = argv[1];
    fs::path out = argv[2];
    uint64_t limit = std::stoull(argv[3]);
    uint64_t start_dirs = argc >= 5 ? std::stoull(argv[4]) : 0;
    fs::create_directories(out);
    Writers w = make_writers(out);
    std::unordered_map<std::string, InventoryRow> inventory;
    uint64_t dirs = 0;
    uint64_t seen_dirs = 0;
    uint64_t xml_files = 0;
    auto t0 = std::chrono::steady_clock::now();

    std::ifstream manifest;
    bool use_manifest = fs::is_regular_file(input);
    if (use_manifest) {
        manifest.open(input);
        if (!manifest) {
            std::cerr << "failed to open manifest: " << input << "\n";
            return 2;
        }
    }

    auto process_dir = [&](const fs::path& dir_path, uint64_t global_dir_index) {
        if (!fs::is_directory(dir_path)) return;
        const std::string dir_acc = dir_path.filename().string();
        auto dir_t0 = std::chrono::steady_clock::now();
        if (dirs > 0 && dirs % 1000 == 0) {
            auto now = std::chrono::steady_clock::now();
            double seconds = std::chrono::duration<double>(now - t0).count();
            std::cerr << "progress dirs=" << dirs << " global_dir_index=" << global_dir_index
                      << " xml_files=" << xml_files << " seconds=" << seconds << " current=" << dir_acc << "\n";
        }
        uint64_t file_count = 0, xml_count = 0, total_xml_bytes = 0;
        std::unordered_set<std::string> kinds;
        std::vector<fs::path> xml_paths;
        for (const auto& child : fs::directory_iterator(dir_path)) {
            if (!child.is_regular_file()) continue;
            ++file_count;
            std::string name = child.path().filename().string();
            if (name.size() >= 4 && name.substr(name.size() - 4) == ".xml") {
                ++xml_count;
                ++xml_files;
                total_xml_bytes += fs::file_size(child.path());
                kinds.insert(xml_kind_from_name(name));
                xml_paths.push_back(child.path());
            }
        }
        for (const auto& xp : xml_paths) parse_xml_file(xp, dir_acc, w, inventory);
        w.directory_index << dir_acc << '\t' << dir_acc.substr(0, std::min<size_t>(3, dir_acc.size())) << '\t'
                          << dir_path.string() << '\t' << file_count << '\t' << xml_count << '\t' << total_xml_bytes << '\t'
                          << (kinds.count("run") ? "true" : "false") << '\t'
                          << (kinds.count("experiment") ? "true" : "false") << '\t'
                          << (kinds.count("sample") ? "true" : "false") << '\t'
                          << (kinds.count("study") ? "true" : "false") << '\t'
                          << (kinds.count("submission") ? "true" : "false") << '\t'
                          << (kinds.count("analysis") ? "true" : "false") << '\t'
                          << "ok\t\n";
        auto dir_t1 = std::chrono::steady_clock::now();
        double dir_seconds = std::chrono::duration<double>(dir_t1 - dir_t0).count();
        if (dir_seconds > 1.0) {
            w.slow_directory_log << global_dir_index << '\t' << dir_acc << '\t' << xml_count << '\t'
                                 << total_xml_bytes << '\t' << dir_seconds << '\n';
            w.slow_directory_log.flush();
        }
        ++dirs;
    };

    if (use_manifest) {
        fs::path dir_path;
        while (seen_dirs < start_dirs && load_next_manifest_path(manifest, dir_path)) ++seen_dirs;
        while (dirs < limit && load_next_manifest_path(manifest, dir_path)) {
            process_dir(dir_path, start_dirs + dirs);
        }
    } else {
        for (const auto& dir_entry : fs::directory_iterator(input)) {
            if (!dir_entry.is_directory()) continue;
            if (seen_dirs++ < start_dirs) continue;
            process_dir(dir_entry.path(), start_dirs + dirs);
            if (dirs >= limit) break;
        }
    }

    auto t1 = std::chrono::steady_clock::now();
    write_inventory(w.path_inventory, inventory);
    double seconds = std::chrono::duration<double>(t1 - t0).count();
    std::ofstream summary(out / "summary.json");
    summary << "{\n"
            << "  \"directory_count\": " << dirs << ",\n"
            << "  \"start_dirs\": " << start_dirs << ",\n"
            << "  \"xml_file_count\": " << xml_files << ",\n"
            << "  \"elapsed_seconds\": " << seconds << "\n"
            << "}\n";
    std::cerr << "done dirs=" << dirs << " xml_files=" << xml_files << " seconds=" << seconds << "\n";
    return 0;
}
