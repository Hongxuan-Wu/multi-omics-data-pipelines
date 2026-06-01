#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

constexpr int kExpectedColumns = 20;
constexpr std::array<const char*, kExpectedColumns> kHeader = {
    "Accession",
    "Submission",
    "Status",
    "Updated",
    "Published",
    "Received",
    "Type",
    "Center",
    "Visibility",
    "Alias",
    "Experiment",
    "Sample",
    "Study",
    "Loaded",
    "Spots",
    "Bases",
    "Md5sum",
    "BioSample",
    "BioProject",
    "ReplacedBy",
};

constexpr std::array<int, 10> kPresenceColumns = {1, 10, 11, 12, 13, 14, 15, 17, 18, 19};
constexpr std::array<const char*, 10> kPresenceNames = {
    "Submission",
    "Experiment",
    "Sample",
    "Study",
    "Loaded",
    "Spots",
    "Bases",
    "BioSample",
    "BioProject",
    "ReplacedBy",
};

struct Stats {
    uint64_t total_lines_including_header = 0;
    uint64_t data_lines = 0;
    std::vector<std::string> header;
    std::unordered_map<std::string, uint64_t> prefix_counts;
    std::unordered_map<std::string, uint64_t> type_counts;
    std::unordered_map<std::string, uint64_t> status_counts;
    std::unordered_map<std::string, uint64_t> visibility_counts;
    std::unordered_map<std::string, uint64_t> center_counts;
    std::unordered_map<std::string, uint64_t> biosample_prefix_counts;
    std::unordered_map<std::string, std::unordered_map<std::string, uint64_t>> prefix_type_matrix;
    std::unordered_map<std::string, uint64_t> presence_counts;
    unsigned __int128 spots_sum = 0;
    unsigned __int128 bases_sum = 0;
    uint64_t spots_non_missing = 0;
    uint64_t bases_non_missing = 0;
    uint64_t spots_max = 0;
    uint64_t bases_max = 0;
};

std::string to_string_u128(unsigned __int128 value) {
    if (value == 0) {
        return "0";
    }
    std::string out;
    while (value > 0) {
        out.push_back(static_cast<char>('0' + (value % 10)));
        value /= 10;
    }
    std::reverse(out.begin(), out.end());
    return out;
}

std::string now_utc_iso() {
    using clock = std::chrono::system_clock;
    auto now = clock::now();
    std::time_t t = clock::to_time_t(now);
    std::tm tm {};
    gmtime_r(&t, &tm);
    std::ostringstream oss;
    oss << std::put_time(&tm, "%Y-%m-%dT%H:%M:%SZ");
    return oss.str();
}

std::string normalize(std::string_view sv) {
    while (!sv.empty() && (sv.back() == '\r' || sv.back() == '\n')) {
        sv.remove_suffix(1);
    }
    return sv.empty() ? "-" : std::string(sv);
}

bool is_missing(std::string_view sv) {
    return sv.empty() || sv == "-";
}

std::string prefix_of(std::string_view sv) {
    if (sv.size() >= 3) {
        if (sv.substr(0, 3) == "SRA") {
            return "SRA";
        }
        if (sv.substr(0, 3) == "ERA") {
            return "ERA";
        }
        if (sv.substr(0, 3) == "DRA") {
            return "DRA";
        }
    }
    return "OTHER";
}

bool parse_u64(std::string_view sv, uint64_t& out) {
    if (is_missing(sv)) {
        return false;
    }
    uint64_t value = 0;
    for (char c : sv) {
        if (c < '0' || c > '9') {
            return false;
        }
        value = value * 10 + static_cast<uint64_t>(c - '0');
    }
    out = value;
    return true;
}

std::vector<std::string> split_line(std::string_view line) {
    std::vector<std::string> out;
    size_t start = 0;
    for (size_t i = 0; i <= line.size(); ++i) {
        if (i == line.size() || line[i] == '\t') {
            out.emplace_back(line.substr(start, i - start));
            start = i + 1;
        }
    }
    return out;
}

template <typename Map>
std::vector<std::pair<std::string, uint64_t>> sort_desc(const Map& map) {
    std::vector<std::pair<std::string, uint64_t>> out(map.begin(), map.end());
    std::sort(out.begin(), out.end(), [](const auto& a, const auto& b) {
        if (a.second != b.second) {
            return a.second > b.second;
        }
        return a.first < b.first;
    });
    return out;
}

void write_json_string(std::ostream& os, const std::string& s) {
    os << '"';
    for (char c : s) {
        switch (c) {
            case '\\': os << "\\\\"; break;
            case '"': os << "\\\""; break;
            case '\n': os << "\\n"; break;
            case '\r': os << "\\r"; break;
            case '\t': os << "\\t"; break;
            default: os << c; break;
        }
    }
    os << '"';
}

void write_pair_list_json(std::ostream& os, const std::unordered_map<std::string, uint64_t>& map, int indent) {
    auto sorted = sort_desc(map);
    os << "[\n";
    for (size_t i = 0; i < sorted.size(); ++i) {
        os << std::string(indent, ' ') << "{";
        os << "\"value\":";
        write_json_string(os, sorted[i].first);
        os << ",\"count\":" << sorted[i].second << "}";
        if (i + 1 != sorted.size()) {
            os << ",";
        }
        os << "\n";
    }
    os << std::string(indent - 2, ' ') << "]";
}

Stats audit_accessions(const std::string& input_path) {
    Stats stats;
    for (const char* name : kPresenceNames) {
        stats.presence_counts[name] = 0;
    }

    std::ifstream input(input_path, std::ios::in | std::ios::binary);
    if (!input) {
        throw std::runtime_error("cannot open input file: " + input_path);
    }
    std::vector<char> buffer(64 * 1024 * 1024);
    input.rdbuf()->pubsetbuf(buffer.data(), static_cast<std::streamsize>(buffer.size()));

    std::string line;
    if (!std::getline(input, line)) {
        throw std::runtime_error("input file is empty");
    }
    stats.total_lines_including_header = 1;
    if (!line.empty() && line.back() == '\r') {
        line.pop_back();
    }
    stats.header = split_line(line);
    if (stats.header.size() != kExpectedColumns) {
        throw std::runtime_error("unexpected column count in header");
    }
    for (size_t i = 0; i < kHeader.size(); ++i) {
        if (stats.header[i] != kHeader[i]) {
            throw std::runtime_error("unexpected header name at column " + std::to_string(i));
        }
    }

    while (std::getline(input, line)) {
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        if (line.empty()) {
            continue;
        }
        ++stats.total_lines_including_header;
        ++stats.data_lines;

        std::array<std::string_view, kExpectedColumns> fields {};
        size_t col = 0;
        size_t start = 0;
        std::string_view line_view(line);
        for (size_t i = 0; i <= line_view.size(); ++i) {
            if (i == line_view.size() || line_view[i] == '\t') {
                if (col >= kExpectedColumns) {
                    throw std::runtime_error("too many columns at data line " + std::to_string(stats.total_lines_including_header));
                }
                fields[col++] = line_view.substr(start, i - start);
                start = i + 1;
            }
        }
        if (col != kExpectedColumns) {
            throw std::runtime_error("too few columns at data line " + std::to_string(stats.total_lines_including_header));
        }

        const std::string prefix = prefix_of(fields[0]);
        const std::string type_value = normalize(fields[6]);
        const std::string status_value = normalize(fields[2]);
        const std::string visibility_value = normalize(fields[8]);
        const std::string center_value = normalize(fields[7]);
        const std::string biosample_value = normalize(fields[17]);

        ++stats.prefix_counts[prefix];
        ++stats.type_counts[type_value];
        ++stats.status_counts[status_value];
        ++stats.visibility_counts[visibility_value];
        ++stats.center_counts[center_value];
        ++stats.prefix_type_matrix[prefix][type_value];

        for (size_t i = 0; i < kPresenceColumns.size(); ++i) {
            if (!is_missing(fields[kPresenceColumns[i]])) {
                ++stats.presence_counts[kPresenceNames[i]];
            }
        }

        if (!is_missing(fields[17])) {
            ++stats.biosample_prefix_counts[prefix_of(fields[17])];
        }

        uint64_t spots = 0;
        if (parse_u64(fields[14], spots)) {
            ++stats.spots_non_missing;
            stats.spots_sum += static_cast<unsigned __int128>(spots);
            if (spots > stats.spots_max) {
                stats.spots_max = spots;
            }
        }

        uint64_t bases = 0;
        if (parse_u64(fields[15], bases)) {
            ++stats.bases_non_missing;
            stats.bases_sum += static_cast<unsigned __int128>(bases);
            if (bases > stats.bases_max) {
                stats.bases_max = bases;
            }
        }
    }

    return stats;
}

void write_json(const Stats& stats, const std::string& input_path, const std::string& script_path, const std::string& output_path) {
    std::ofstream os(output_path);
    if (!os) {
        throw std::runtime_error("cannot open output json: " + output_path);
    }

    os << "{\n";
    os << "  \"input_path\": ";
    write_json_string(os, input_path);
    os << ",\n";
    os << "  \"script_path\": ";
    write_json_string(os, script_path);
    os << ",\n";
    os << "  \"generated_at_utc\": ";
    write_json_string(os, now_utc_iso());
    os << ",\n";
    os << "  \"total_lines_including_header\": " << stats.total_lines_including_header << ",\n";
    os << "  \"data_lines\": " << stats.data_lines << ",\n";
    os << "  \"column_count\": " << stats.header.size() << ",\n";
    os << "  \"header\": [";
    for (size_t i = 0; i < stats.header.size(); ++i) {
        if (i) {
            os << ", ";
        }
        write_json_string(os, stats.header[i]);
    }
    os << "],\n";

    os << "  \"prefix_counts\": ";
    write_pair_list_json(os, stats.prefix_counts, 4);
    os << ",\n";
    os << "  \"type_counts\": ";
    write_pair_list_json(os, stats.type_counts, 4);
    os << ",\n";
    os << "  \"status_counts\": ";
    write_pair_list_json(os, stats.status_counts, 4);
    os << ",\n";
    os << "  \"visibility_counts\": ";
    write_pair_list_json(os, stats.visibility_counts, 4);
    os << ",\n";
    os << "  \"center_counts_top20\": [\n";
    auto centers = sort_desc(stats.center_counts);
    for (size_t i = 0; i < centers.size() && i < 20; ++i) {
        os << "    {\"value\":";
        write_json_string(os, centers[i].first);
        os << ",\"count\":" << centers[i].second << "}";
        if (i + 1 < centers.size() && i + 1 < 20) {
            os << ",";
        }
        os << "\n";
    }
    os << "  ],\n";
    os << "  \"biosample_prefix_counts\": ";
    write_pair_list_json(os, stats.biosample_prefix_counts, 4);
    os << ",\n";
    os << "  \"presence_counts\": {\n";
    for (size_t i = 0; i < kPresenceNames.size(); ++i) {
        os << "    ";
        write_json_string(os, kPresenceNames[i]);
        os << ": " << stats.presence_counts.at(kPresenceNames[i]);
        if (i + 1 != kPresenceNames.size()) {
            os << ",";
        }
        os << "\n";
    }
    os << "  },\n";
    os << "  \"prefix_type_matrix\": {\n";
    auto prefixes = sort_desc(stats.prefix_counts);
    for (size_t i = 0; i < prefixes.size(); ++i) {
        os << "    ";
        write_json_string(os, prefixes[i].first);
        os << ": {";
        auto inner = sort_desc(stats.prefix_type_matrix.at(prefixes[i].first));
        for (size_t j = 0; j < inner.size(); ++j) {
            if (j) {
                os << ", ";
            }
            write_json_string(os, inner[j].first);
            os << ": " << inner[j].second;
        }
        os << "}";
        if (i + 1 != prefixes.size()) {
            os << ",";
        }
        os << "\n";
    }
    os << "  },\n";
    os << "  \"spots_non_missing\": " << stats.spots_non_missing << ",\n";
    os << "  \"spots_sum\": ";
    write_json_string(os, to_string_u128(stats.spots_sum));
    os << ",\n";
    os << "  \"spots_max\": " << stats.spots_max << ",\n";
    os << "  \"bases_non_missing\": " << stats.bases_non_missing << ",\n";
    os << "  \"bases_sum\": ";
    write_json_string(os, to_string_u128(stats.bases_sum));
    os << ",\n";
    os << "  \"bases_max\": " << stats.bases_max << "\n";
    os << "}\n";
}

void write_markdown(const Stats& stats, const std::string& input_path, const std::string& script_path, const std::string& json_path, const std::string& output_path) {
    std::ofstream os(output_path);
    if (!os) {
        throw std::runtime_error("cannot open output markdown: " + output_path);
    }

    os << "# SRA_Accessions 审计报告\n\n";
    os << "- 输入文件: `" << input_path << "`\n";
    os << "- 代码路径: `" << script_path << "`\n";
    os << "- JSON 结果: `" << json_path << "`\n";
    os << "- 总行数(含表头): `" << stats.total_lines_including_header << "`\n";
    os << "- 数据行数(不含表头): `" << stats.data_lines << "`\n";
    os << "- 字段数: `" << stats.header.size() << "`\n";
    os << "- 表头: `";
    for (size_t i = 0; i < stats.header.size(); ++i) {
        if (i) {
            os << ", ";
        }
        os << stats.header[i];
    }
    os << "`\n\n";

    os << "## Accession 前缀分布\n";
    for (const auto& kv : sort_desc(stats.prefix_counts)) {
        os << "- `" << kv.first << "`: `" << kv.second << "`\n";
    }
    os << "\n## Type 分布\n";
    for (const auto& kv : sort_desc(stats.type_counts)) {
        os << "- `" << kv.first << "`: `" << kv.second << "`\n";
    }
    os << "\n## Status 分布\n";
    for (const auto& kv : sort_desc(stats.status_counts)) {
        os << "- `" << kv.first << "`: `" << kv.second << "`\n";
    }
    os << "\n## Visibility 分布\n";
    for (const auto& kv : sort_desc(stats.visibility_counts)) {
        os << "- `" << kv.first << "`: `" << kv.second << "`\n";
    }
    os << "\n## 前缀 × Type\n";
    for (const auto& prefix : sort_desc(stats.prefix_counts)) {
        os << "- `" << prefix.first << "`: ";
        auto inner = sort_desc(stats.prefix_type_matrix.at(prefix.first));
        for (size_t i = 0; i < inner.size(); ++i) {
            if (i) {
                os << ", ";
            }
            os << inner[i].first << "=" << inner[i].second;
        }
        os << "\n";
    }
    os << "\n## 关键字段非缺失计数\n";
    for (const char* name : kPresenceNames) {
        os << "- `" << name << "`: `" << stats.presence_counts.at(name) << "`\n";
    }
    os << "\n## 数值字段\n";
    os << "- `Spots` 非缺失: `" << stats.spots_non_missing << "`\n";
    os << "- `Spots` 总和: `" << to_string_u128(stats.spots_sum) << "`\n";
    os << "- `Spots` 最大值: `" << stats.spots_max << "`\n";
    os << "- `Bases` 非缺失: `" << stats.bases_non_missing << "`\n";
    os << "- `Bases` 总和: `" << to_string_u128(stats.bases_sum) << "`\n";
    os << "- `Bases` 最大值: `" << stats.bases_max << "`\n";
    os << "\n## Top 20 Center\n";
    auto centers = sort_desc(stats.center_counts);
    for (size_t i = 0; i < centers.size() && i < 20; ++i) {
        os << "- `" << centers[i].first << "`: `" << centers[i].second << "`\n";
    }
    os << "\n## BioSample 前缀分布\n";
    for (const auto& kv : sort_desc(stats.biosample_prefix_counts)) {
        os << "- `" << kv.first << "`: `" << kv.second << "`\n";
    }
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 5) {
        std::cerr << "Usage: " << argv[0] << " <input> <json_out> <md_out> <script_path>\n";
        return 1;
    }

    const std::string input_path = argv[1];
    const std::string json_out = argv[2];
    const std::string md_out = argv[3];
    const std::string script_path = argv[4];

    try {
        Stats stats = audit_accessions(input_path);
        write_json(stats, input_path, script_path, json_out);
        write_markdown(stats, input_path, script_path, json_out, md_out);
    } catch (const std::exception& ex) {
        std::cerr << ex.what() << "\n";
        return 1;
    }
    return 0;
}
