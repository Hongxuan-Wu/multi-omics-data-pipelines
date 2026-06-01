#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <unordered_map>
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

constexpr std::array<int, 6> kPresenceColumns = {10, 11, 12, 13, 17, 18};
constexpr std::array<const char*, 6> kPresenceNames = {
    "Experiment",
    "Sample",
    "Study",
    "Loaded",
    "BioSample",
    "BioProject",
};

struct ChunkStats {
    uint64_t data_lines = 0;
    std::unordered_map<std::string, uint64_t> prefix_counts;
    std::unordered_map<std::string, uint64_t> type_counts;
    std::unordered_map<std::string, uint64_t> status_counts;
    std::unordered_map<std::string, uint64_t> visibility_counts;
    std::unordered_map<std::string, std::unordered_map<std::string, uint64_t>> prefix_type_matrix;
    std::unordered_map<std::string, uint64_t> presence_counts;
};

std::string prefix_of(std::string_view sv) {
    if (sv.size() >= 3) {
        if (sv.substr(0, 3) == "SRA") return "SRA";
        if (sv.substr(0, 3) == "ERA") return "ERA";
        if (sv.substr(0, 3) == "DRA") return "DRA";
    }
    return "OTHER";
}

bool is_missing(std::string_view sv) {
    return sv.empty() || sv == "-";
}

std::string normalize(std::string_view sv) {
    return is_missing(sv) ? "-" : std::string(sv);
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

off_t file_size_of(const std::string& path) {
    struct stat st {};
    if (stat(path.c_str(), &st) != 0) {
        throw std::runtime_error("stat failed for " + path);
    }
    return st.st_size;
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

template <typename Map>
std::vector<std::pair<std::string, uint64_t>> sort_desc(const Map& map) {
    std::vector<std::pair<std::string, uint64_t>> out(map.begin(), map.end());
    std::sort(out.begin(), out.end(), [](const auto& a, const auto& b) {
        if (a.second != b.second) return a.second > b.second;
        return a.first < b.first;
    });
    return out;
}

void write_counter_json(std::ostream& os, const std::unordered_map<std::string, uint64_t>& map, int indent) {
    auto sorted = sort_desc(map);
    os << "{\n";
    for (size_t i = 0; i < sorted.size(); ++i) {
        os << std::string(indent, ' ');
        write_json_string(os, sorted[i].first);
        os << ": " << sorted[i].second;
        if (i + 1 != sorted.size()) os << ",";
        os << "\n";
    }
    os << std::string(indent - 2, ' ') << "}";
}

void process_line(const std::string& line, ChunkStats& stats) {
    std::array<std::string_view, kExpectedColumns> fields {};
    std::string_view view(line);
    size_t col = 0;
    size_t start = 0;
    for (size_t i = 0; i <= view.size(); ++i) {
        if (i == view.size() || view[i] == '\t') {
            if (col >= kExpectedColumns) {
                throw std::runtime_error("too many columns in line");
            }
            fields[col++] = view.substr(start, i - start);
            start = i + 1;
        }
    }
    if (col != kExpectedColumns) {
        throw std::runtime_error("unexpected column count in line");
    }

    const std::string prefix = prefix_of(fields[0]);
    const std::string type_value = normalize(fields[6]);
    const std::string status_value = normalize(fields[2]);
    const std::string visibility_value = normalize(fields[8]);

    ++stats.data_lines;
    ++stats.prefix_counts[prefix];
    ++stats.type_counts[type_value];
    ++stats.status_counts[status_value];
    ++stats.visibility_counts[visibility_value];
    ++stats.prefix_type_matrix[prefix][type_value];

    for (size_t i = 0; i < kPresenceColumns.size(); ++i) {
        if (!is_missing(fields[kPresenceColumns[i]])) {
            ++stats.presence_counts[kPresenceNames[i]];
        }
    }
}

ChunkStats audit_chunk(const std::string& input_path, uint64_t start_byte, uint64_t end_byte, bool include_header) {
    ChunkStats stats;
    for (const char* name : kPresenceNames) {
        stats.presence_counts[name] = 0;
    }

    std::ifstream input(input_path, std::ios::binary);
    if (!input) {
        throw std::runtime_error("cannot open input file");
    }
    std::vector<char> buffer(32 * 1024 * 1024);
    input.rdbuf()->pubsetbuf(buffer.data(), static_cast<std::streamsize>(buffer.size()));
    input.seekg(static_cast<std::streamoff>(start_byte));
    if (!input) {
        throw std::runtime_error("seekg failed");
    }

    std::string line;
    if (start_byte > 0) {
        std::getline(input, line);
    }

    bool first_line = include_header;
    while (true) {
        std::streampos line_start_pos = input.tellg();
        if (line_start_pos == std::streampos(-1)) {
            break;
        }
        uint64_t line_start = static_cast<uint64_t>(line_start_pos);
        if (line_start >= end_byte) {
            break;
        }
        if (!std::getline(input, line)) {
            break;
        }
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        if (first_line) {
            auto header = split_line(line);
            if (header.size() != kExpectedColumns) {
                throw std::runtime_error("header column count mismatch");
            }
            for (size_t i = 0; i < kHeader.size(); ++i) {
                if (header[i] != kHeader[i]) {
                    throw std::runtime_error("header name mismatch");
                }
            }
            first_line = false;
            continue;
        }
        if (line.empty()) {
            continue;
        }
        process_line(line, stats);
    }
    return stats;
}

void write_chunk_json(
    const ChunkStats& stats,
    const std::string& input_path,
    uint64_t start_byte,
    uint64_t end_byte,
    const std::string& output_path
) {
    std::ofstream os(output_path);
    if (!os) {
        throw std::runtime_error("cannot open output file");
    }
    os << "{\n";
    os << "  \"input_path\": ";
    write_json_string(os, input_path);
    os << ",\n";
    os << "  \"start_byte\": " << start_byte << ",\n";
    os << "  \"end_byte\": " << end_byte << ",\n";
    os << "  \"data_lines\": " << stats.data_lines << ",\n";
    os << "  \"prefix_counts\": ";
    write_counter_json(os, stats.prefix_counts, 4);
    os << ",\n";
    os << "  \"type_counts\": ";
    write_counter_json(os, stats.type_counts, 4);
    os << ",\n";
    os << "  \"status_counts\": ";
    write_counter_json(os, stats.status_counts, 4);
    os << ",\n";
    os << "  \"visibility_counts\": ";
    write_counter_json(os, stats.visibility_counts, 4);
    os << ",\n";
    os << "  \"presence_counts\": ";
    write_counter_json(os, stats.presence_counts, 4);
    os << ",\n";
    os << "  \"prefix_type_matrix\": {\n";
    auto prefixes = sort_desc(stats.prefix_counts);
    for (size_t i = 0; i < prefixes.size(); ++i) {
        os << "    ";
        write_json_string(os, prefixes[i].first);
        os << ": ";
        write_counter_json(os, stats.prefix_type_matrix.at(prefixes[i].first), 6);
        if (i + 1 != prefixes.size()) os << ",";
        os << "\n";
    }
    os << "  }\n";
    os << "}\n";
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 6) {
        std::cerr << "Usage: " << argv[0] << " <input> <start_byte> <end_byte> <include_header:0|1> <json_out>\n";
        return 1;
    }
    const std::string input_path = argv[1];
    const uint64_t start_byte = std::stoull(argv[2]);
    const uint64_t end_byte = std::stoull(argv[3]);
    const bool include_header = std::string(argv[4]) == "1";
    const std::string output_path = argv[5];

    try {
        const off_t file_size = file_size_of(input_path);
        const uint64_t clamped_end = std::min<uint64_t>(end_byte, static_cast<uint64_t>(file_size));
        ChunkStats stats = audit_chunk(input_path, start_byte, clamped_end, include_header);
        write_chunk_json(stats, input_path, start_byte, clamped_end, output_path);
    } catch (const std::exception& ex) {
        std::cerr << ex.what() << "\n";
        return 1;
    }
    return 0;
}
