#include <algorithm>
#include <array>
#include <charconv>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <memory>
#include <sstream>
#include <cctype>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace fs = std::filesystem;
constexpr int kBuckets = 256;
constexpr int kIndexStride = 64;
constexpr int kLimit = 128;
constexpr uint32_t kVersion = 1;

struct TransparentHash {
    using is_transparent = void;
    size_t operator()(std::string_view v) const noexcept {
        return std::hash<std::string_view>{}(v);
    }
};

#pragma pack(push, 1)
struct RawRecord {
    uint16_t ids[5]{};
    float probability{};
    float backoff{};
};
struct SectionHeader {
    uint64_t directory_offset{};
    uint64_t block_count{};
    uint64_t record_count{};
};
struct QuantHeader {
    int32_t probability_min_e7{};
    uint32_t probability_step_e12{};
    int32_t backoff_min_e7{};
    uint32_t backoff_step_e12{};
};
struct Header {
    char magic[8]{};
    uint32_t version{};
    uint32_t header_size{};
    uint64_t file_size{};
    uint32_t order{};
    uint32_t vocab_count{};
    uint32_t bucket_count{};
    uint32_t index_stride{};
    uint64_t vocab_offset{};
    uint64_t vocab_bytes{};
    uint16_t unknown_id{};
    uint16_t bos_id{};
    uint16_t eos_id{};
    uint16_t reserved0{};
    SectionHeader sections[4]{};
    QuantHeader quant[5]{};
    uint8_t reserved[16]{};
};
struct BucketMeta {
    uint64_t blocks_offset{};
    uint64_t blocks_bytes{};
    uint64_t index_offset{};
    uint32_t index_count{};
    uint32_t block_count{};
    uint64_t record_count{};
};
struct IndexEntry {
    uint16_t ids[4]{};
    uint64_t offset{};
};
#pragma pack(pop)

static_assert(sizeof(RawRecord) == 18);
static_assert(sizeof(Header) == 256);
static_assert(sizeof(BucketMeta) == 40);
static_assert(sizeof(IndexEntry) == 16);

struct Range {
    float minimum = std::numeric_limits<float>::infinity();
    float maximum = -std::numeric_limits<float>::infinity();
    bool any = false;
    void add(float value) {
        minimum = std::min(minimum, value);
        maximum = std::max(maximum, value);
        any = true;
    }
};

struct Uni {
    std::string token;
    float probability{};
    float backoff{};
    uint16_t id{};
    int rank{};
};

float parse_float(std::string_view value) {
    float result = 0;
    auto parsed = std::from_chars(value.data(), value.data() + value.size(), result);
    if (parsed.ec != std::errc() || parsed.ptr != value.data() + value.size())
        throw std::runtime_error("invalid float");
    return result;
}

int split_fields(const std::string& line, std::array<std::string_view, 8>& fields) {
    int count = 0;
    size_t i = 0;
    while (i < line.size()) {
        while (i < line.size() && std::isspace(static_cast<unsigned char>(line[i]))) ++i;
        size_t begin = i;
        while (i < line.size() && !std::isspace(static_cast<unsigned char>(line[i]))) ++i;
        if (i > begin) {
            if (count >= static_cast<int>(fields.size())) throw std::runtime_error("too many ARPA fields");
            fields[count++] = std::string_view(line).substr(begin, i - begin);
        }
    }
    return count;
}

fs::path bucket_path(const fs::path& temp, int order, int bucket) {
    std::ostringstream name;
    name << "o" << order << "_b" << std::setw(3) << std::setfill('0') << bucket << ".raw";
    return temp / name.str();
}

class BucketWriters {
public:
    BucketWriters(const fs::path& temp, int order) : order_(order) {
        for (int b = 0; b < kBuckets; ++b) {
            streams_[b].open(bucket_path(temp, order, b), std::ios::binary | std::ios::trunc);
            if (!streams_[b]) throw std::runtime_error("cannot create temporary bucket");
            buffers_[b].reserve(4096);
        }
    }
    ~BucketWriters() { close(); }
    void append(int bucket, const RawRecord& record) {
        auto& buffer = buffers_[bucket];
        buffer.push_back(record);
        if (buffer.size() >= 4096) flush(bucket);
    }
    void close() {
        if (closed_) return;
        for (int b = 0; b < kBuckets; ++b) {
            flush(b);
            streams_[b].close();
        }
        closed_ = true;
    }
private:
    void flush(int bucket) {
        auto& buffer = buffers_[bucket];
        if (buffer.empty()) return;
        streams_[bucket].write(reinterpret_cast<const char*>(buffer.data()),
            static_cast<std::streamsize>(buffer.size() * sizeof(RawRecord)));
        if (!streams_[bucket]) throw std::runtime_error("temporary bucket write failed");
        buffer.clear();
    }
    int order_{};
    bool closed_ = false;
    std::array<std::ofstream, kBuckets> streams_;
    std::array<std::vector<RawRecord>, kBuckets> buffers_;
};

struct BuildState {
    std::vector<Uni> vocab;
    std::unordered_map<std::string, uint16_t, TransparentHash, std::equal_to<>> ids;
    std::array<Range, 5> probability;
    std::array<Range, 4> backoff_nonzero;
    std::array<uint64_t, 5> records{};
    uint16_t unknown{};
    uint16_t bos{};
    uint16_t eos{};
};

void finalize_vocab(BuildState& state) {
    if (state.vocab.empty() || state.vocab.size() >= 65535)
        throw std::runtime_error("vocabulary must fit uint16");
    std::vector<size_t> by_token(state.vocab.size());
    for (size_t i = 0; i < by_token.size(); ++i) by_token[i] = i;
    std::sort(by_token.begin(), by_token.end(), [&](size_t a, size_t b) {
        return state.vocab[a].token < state.vocab[b].token;
    });
    std::vector<Uni> sorted;
    sorted.reserve(state.vocab.size());
    for (size_t index : by_token) sorted.push_back(std::move(state.vocab[index]));
    state.vocab = std::move(sorted);
    state.ids.reserve(state.vocab.size() * 2);
    for (size_t i = 0; i < state.vocab.size(); ++i) {
        state.vocab[i].id = static_cast<uint16_t>(i);
        state.ids.emplace(state.vocab[i].token, static_cast<uint16_t>(i));
    }
    std::vector<size_t> by_probability;
    for (size_t i = 0; i < state.vocab.size(); ++i) {
        const auto& token = state.vocab[i].token;
        if (token != "<s>" && token != "</s>" && token != "<unk>") by_probability.push_back(i);
    }
    std::sort(by_probability.begin(), by_probability.end(), [&](size_t a, size_t b) {
        if (state.vocab[a].probability != state.vocab[b].probability)
            return state.vocab[a].probability > state.vocab[b].probability;
        return state.vocab[a].token < state.vocab[b].token;
    });
    for (size_t i = 0; i < by_probability.size(); ++i)
        state.vocab[by_probability[i]].rank = static_cast<int>(i + 1);
    auto required = [&](const char* token) -> uint16_t {
        auto found = state.ids.find(token);
        if (found == state.ids.end()) throw std::runtime_error(std::string("missing token ") + token);
        return found->second;
    };
    state.unknown = required("<unk>");
    state.bos = required("<s>");
    state.eos = required("</s>");
}

BuildState partition_arpa(const fs::path& arpa, const fs::path& temp) {
    fs::create_directories(temp);
    BuildState state;
    std::ifstream input;
    std::vector<char> read_buffer(8 * 1024 * 1024);
    input.rdbuf()->pubsetbuf(read_buffer.data(), read_buffer.size());
    input.open(arpa);
    if (!input) throw std::runtime_error("cannot open ARPA");
    std::unique_ptr<BucketWriters> writers;
    int section = 0;
    std::string line;
    std::array<std::string_view, 8> fields;
    uint64_t seen = 0;
    while (std::getline(input, line)) {
        if (line.size() > 3 && line[0] == '\\' && line.find("-grams:") != std::string::npos) {
            int next = line[1] - '0';
            if (next < 1 || next > 5) throw std::runtime_error("unexpected ARPA order");
            if (writers) writers->close();
            if (section == 1 && next == 2) finalize_vocab(state);
            section = next;
            if (section >= 2) writers = std::make_unique<BucketWriters>(temp, section);
            continue;
        }
        if (section == 0 || line.empty() || line[0] == '\\') continue;
        int count = split_fields(line, fields);
        if (count != section + 1 && count != section + 2)
            throw std::runtime_error("invalid ARPA record");
        float probability = parse_float(fields[0]);
        float backoff = count == section + 2 ? parse_float(fields[section + 1]) : 0.0f;
        if (section == 1) {
            Uni uni{std::string(fields[1]), probability, backoff};
            state.vocab.push_back(std::move(uni));
            state.probability[0].add(probability);
            if (backoff != 0) state.backoff_nonzero[0].add(backoff);
            state.records[0]++;
            continue;
        }
        RawRecord record{};
        int history_max = 0, full_max = 0;
        bool history_allowed = true;
        for (int i = 0; i < section; ++i) {
            auto found = state.ids.find(fields[i + 1]);
            if (found == state.ids.end()) throw std::runtime_error("ARPA token absent from vocabulary");
            uint16_t id = found->second;
            record.ids[i] = id;
            int rank = state.vocab[id].rank;
            full_max = std::max(full_max, rank);
            if (i < section - 1) {
                history_max = std::max(history_max, rank);
                if (section >= 4 && history_max > kLimit) history_allowed = false;
            }
        }
        if (!history_allowed) continue;
        if ((section == 3 || section == 4) && full_max > kLimit) backoff = 0.0f;
        record.probability = probability;
        record.backoff = backoff;
        state.probability[section - 1].add(probability);
        if (section <= 4 && backoff != 0) state.backoff_nonzero[section - 1].add(backoff);
        state.records[section - 1]++;
        writers->append(record.ids[0] & 0xff, record);
        if (++seen % 10000000 == 0)
            std::cerr << "retained " << seen << " records, order " << section << "\n";
    }
    if (writers) writers->close();
    if (!input.eof() || section != 5) throw std::runtime_error("incomplete ARPA scan");
    std::cerr << "vocabulary " << state.vocab.size();
    for (int order = 1; order <= 5; ++order) std::cerr << " o" << order << "=" << state.records[order - 1];
    std::cerr << "\n";
    return state;
}

uint16_t quantize_probability(float value, const Range& range) {
    if (!range.any || range.maximum <= range.minimum) return 0;
    double scaled = (static_cast<double>(value) - range.minimum) * 65535.0 /
        (static_cast<double>(range.maximum) - range.minimum);
    long q = std::lround(scaled);
    return static_cast<uint16_t>(std::clamp<long>(q, 0, 65535));
}

uint16_t quantize_backoff(float value, const Range& range) {
    if (value == 0.0f) return 0;
    if (!range.any || range.maximum <= range.minimum) return 1;
    double scaled = (static_cast<double>(value) - range.minimum) * 65534.0 /
        (static_cast<double>(range.maximum) - range.minimum);
    long q = 1 + std::lround(scaled);
    return static_cast<uint16_t>(std::clamp<long>(q, 1, 65535));
}

void write_u16(std::ostream& out, uint16_t value) {
    out.write(reinterpret_cast<const char*>(&value), sizeof(value));
}

std::vector<RawRecord> load_records(const fs::path& path) {
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    if (!input) throw std::runtime_error("cannot open bucket for reading");
    auto bytes = input.tellg();
    if (bytes < 0 || static_cast<uint64_t>(bytes) % sizeof(RawRecord) != 0)
        throw std::runtime_error("invalid bucket size");
    std::vector<RawRecord> records(static_cast<size_t>(
        static_cast<uint64_t>(bytes) / sizeof(RawRecord)));
    input.seekg(0);
    if (!records.empty()) {
        input.read(reinterpret_cast<char*>(records.data()),
            static_cast<std::streamsize>(records.size() * sizeof(RawRecord)));
        if (!input) throw std::runtime_error("bucket read failed");
    }
    return records;
}

bool key_less(const RawRecord& a, const RawRecord& b, int order) {
    for (int i = 0; i < order; ++i) {
        if (a.ids[i] != b.ids[i]) return a.ids[i] < b.ids[i];
    }
    return false;
}

int compare_context(const uint16_t* left, const uint16_t* right, int length) {
    for (int i = 0; i < length; ++i) {
        if (left[i] < right[i]) return -1;
        if (left[i] > right[i]) return 1;
    }
    return 0;
}

bool same_context(const RawRecord& a, const RawRecord& b, int length) {
    return compare_context(a.ids, b.ids, length) == 0;
}

void save_sorted(const fs::path& path, const std::vector<RawRecord>& records) {
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    if (!output) throw std::runtime_error("cannot rewrite sorted bucket");
    if (!records.empty())
        output.write(reinterpret_cast<const char*>(records.data()),
            static_cast<std::streamsize>(records.size() * sizeof(RawRecord)));
    if (!output) throw std::runtime_error("sorted bucket write failed");
}

struct ContextSource {
    std::array<uint16_t, 4> ids{};
    float backoff{};
};

std::vector<ContextSource> unigram_contexts(const BuildState& state, int bucket) {
    std::vector<ContextSource> result;
    for (const auto& uni : state.vocab) {
        if ((uni.id & 0xff) == bucket && uni.backoff != 0.0f) {
            ContextSource value{};
            value.ids[0] = uni.id;
            value.backoff = uni.backoff;
            result.push_back(value);
        }
    }
    std::sort(result.begin(), result.end(), [](const auto& a, const auto& b) {
        return a.ids[0] < b.ids[0];
    });
    return result;
}

std::vector<ContextSource> previous_contexts(
    const std::vector<RawRecord>& previous, int previous_order) {
    std::vector<ContextSource> result;
    result.reserve(previous.size() / 4 + 1);
    for (const auto& record : previous) {
        if (record.backoff == 0.0f) continue;
        ContextSource value{};
        for (int i = 0; i < previous_order; ++i) value.ids[i] = record.ids[i];
        value.backoff = record.backoff;
        result.push_back(value);
    }
    return result;
}

uint64_t tell(std::ostream& out) {
    auto at = out.tellp();
    if (at < 0) throw std::runtime_error("output position failed");
    return static_cast<uint64_t>(at);
}

void write_vocab(std::ostream& out, const BuildState& state) {
    for (const auto& uni : state.vocab) {
        if (uni.token.size() > 65535) throw std::runtime_error("token too long");
        write_u16(out, static_cast<uint16_t>(uni.token.size()));
        out.write(uni.token.data(), static_cast<std::streamsize>(uni.token.size()));
        write_u16(out, quantize_probability(uni.probability, state.probability[0]));
        write_u16(out, quantize_backoff(uni.backoff, state.backoff_nonzero[0]));
    }
}

void emit_block(
    std::ostream& output,
    int order,
    const std::array<uint16_t, 4>& context,
    float backoff,
    const std::vector<RawRecord>& current,
    size_t begin,
    size_t end,
    const BuildState& state,
    std::vector<IndexEntry>& index,
    uint32_t block_number) {
    if (end - begin > 65535) throw std::runtime_error("context successor count exceeds uint16");
    if (block_number % kIndexStride == 0) {
        IndexEntry entry{};
        for (int i = 0; i < 4; ++i) entry.ids[i] = context[i];
        entry.offset = tell(output);
        index.push_back(entry);
    }
    for (int i = 0; i < order - 1; ++i) write_u16(output, context[i]);
    write_u16(output, quantize_backoff(backoff, state.backoff_nonzero[order - 2]));
    write_u16(output, static_cast<uint16_t>(end - begin));
    for (size_t i = begin; i < end; ++i) {
        write_u16(output, current[i].ids[order - 1]);
        write_u16(output, quantize_probability(
            current[i].probability, state.probability[order - 1]));
    }
}

BucketMeta build_bucket(
    std::ostream& output,
    const fs::path& temp,
    int order,
    int bucket,
    BuildState& state) {
    auto current_path = bucket_path(temp, order, bucket);
    auto current = load_records(current_path);
    std::sort(current.begin(), current.end(), [&](const auto& a, const auto& b) {
        return key_less(a, b, order);
    });
    save_sorted(current_path, current);

    std::vector<ContextSource> bows;
    if (order == 2) {
        bows = unigram_contexts(state, bucket);
    } else {
        auto previous = load_records(bucket_path(temp, order - 1, bucket));
        if (!std::is_sorted(previous.begin(), previous.end(), [&](const auto& a, const auto& b) {
            return key_less(a, b, order - 1);
        })) throw std::runtime_error("previous bucket was not sorted");
        bows = previous_contexts(previous, order - 1);
    }

    BucketMeta meta{};
    meta.blocks_offset = tell(output);
    std::vector<IndexEntry> index;
    size_t ci = 0, bi = 0;
    uint32_t block_count = 0;
    uint64_t successor_count = 0;

    auto current_context = [&](size_t at) {
        std::array<uint16_t, 4> key{};
        for (int i = 0; i < order - 1; ++i) key[i] = current[at].ids[i];
        return key;
    };

    while (ci < current.size() || bi < bows.size()) {
        std::array<uint16_t, 4> ck{};
        bool has_current = ci < current.size();
        if (has_current) ck = current_context(ci);
        bool has_bow = bi < bows.size();
        int compared = 0;
        if (has_current && has_bow)
            compared = compare_context(ck.data(), bows[bi].ids.data(), order - 1);

        if (has_bow && (!has_current || compared > 0)) {
            emit_block(output, order, bows[bi].ids, bows[bi].backoff,
                current, ci, ci, state, index, block_count++);
            ++bi;
            continue;
        }

        size_t end = ci;
        while (end < current.size() &&
            compare_context(current[end].ids, ck.data(), order - 1) == 0) ++end;
        float bow = 0.0f;
        if (has_bow && compared == 0) {
            bow = bows[bi].backoff;
            ++bi;
        }
        emit_block(output, order, ck, bow, current, ci, end,
            state, index, block_count++);
        successor_count += end - ci;
        ci = end;
    }

    meta.blocks_bytes = tell(output) - meta.blocks_offset;
    meta.index_offset = tell(output);
    for (const auto& entry : index)
        output.write(reinterpret_cast<const char*>(&entry), sizeof(entry));
    meta.index_count = static_cast<uint32_t>(index.size());
    meta.block_count = block_count;
    meta.record_count = successor_count;
    if (!output) throw std::runtime_error("output bucket write failed");
    return meta;
}

void build_model(
    const fs::path& arpa,
    const fs::path& destination,
    const fs::path& temp) {
    if (fs::exists(destination)) throw std::runtime_error("destination already exists");
    fs::remove_all(temp);
    fs::create_directories(temp);
    BuildState state = partition_arpa(arpa, temp);

    Header header{};
    std::memcpy(header.magic, "TCSKNM03", 8);
    header.version = kVersion;
    header.header_size = sizeof(Header);
    header.order = 5;
    header.vocab_count = static_cast<uint32_t>(state.vocab.size());
    header.bucket_count = kBuckets;
    header.index_stride = kIndexStride;
    header.unknown_id = state.unknown;
    header.bos_id = state.bos;
    header.eos_id = state.eos;
    for (int i = 0; i < 5; ++i) {
        const auto& p = state.probability[i];
        if (!p.any) throw std::runtime_error("missing probability range");
        header.quant[i].probability_min_e7 = static_cast<int32_t>(std::llround(static_cast<double>(p.minimum) * 1e7));
        header.quant[i].probability_step_e12 = p.maximum > p.minimum
            ? static_cast<uint32_t>(std::llround((static_cast<double>(p.maximum) - p.minimum) / 65535.0 * 1e12)) : 0;
        if (i < 4) {
            const auto& b = state.backoff_nonzero[i];
            header.quant[i].backoff_min_e7 = b.any ? static_cast<int32_t>(std::llround(static_cast<double>(b.minimum) * 1e7)) : 0;
            header.quant[i].backoff_step_e12 = b.any && b.maximum > b.minimum
                ? static_cast<uint32_t>(std::llround((static_cast<double>(b.maximum) - b.minimum) / 65534.0 * 1e12)) : 0;
        }
    }

    fs::create_directories(destination.parent_path());
    std::ofstream output(destination, std::ios::binary | std::ios::trunc);
    if (!output) throw std::runtime_error("cannot create destination");
    output.write(reinterpret_cast<const char*>(&header), sizeof(header));

    std::array<std::array<BucketMeta, kBuckets>, 4> directories{};
    for (int section = 0; section < 4; ++section) {
        header.sections[section].directory_offset = tell(output);
        std::array<BucketMeta, kBuckets> empty{};
        output.write(reinterpret_cast<const char*>(empty.data()), sizeof(empty));
    }

    header.vocab_offset = tell(output);
    write_vocab(output, state);
    header.vocab_bytes = tell(output) - header.vocab_offset;

    for (int order = 2; order <= 5; ++order) {
        auto& section = header.sections[order - 2];
        uint64_t records = 0;
        uint64_t blocks = 0;
        std::cerr << "packing order " << order << "\n";
        for (int bucket = 0; bucket < kBuckets; ++bucket) {
            auto meta = build_bucket(output, temp, order, bucket, state);
            directories[order - 2][bucket] = meta;
            records += meta.record_count;
            blocks += meta.block_count;
            if (bucket % 32 == 31)
                std::cerr << "  buckets " << (bucket + 1) << "/256 records=" << records
                          << " blocks=" << blocks << "\n";
        }
        section.record_count = records;
        section.block_count = blocks;
        if (records != state.records[order - 1])
            throw std::runtime_error("packed record count mismatch");
    }

    header.file_size = tell(output);
    for (int section = 0; section < 4; ++section) {
        output.seekp(static_cast<std::streamoff>(header.sections[section].directory_offset));
        output.write(reinterpret_cast<const char*>(directories[section].data()),
            sizeof(directories[section]));
    }
    output.seekp(0);
    output.write(reinterpret_cast<const char*>(&header), sizeof(header));
    output.flush();
    if (!output) throw std::runtime_error("final output write failed");
    output.close();

    std::cout << "TCSKNM03 " << destination << " bytes=" << header.file_size
              << " vocab=" << header.vocab_count << "\n";
    for (int order = 1; order <= 5; ++order) {
        std::cout << "order" << order << " records=" << state.records[order - 1]
                  << " p=[" << state.probability[order - 1].minimum << ","
                  << state.probability[order - 1].maximum << "]";
        if (order < 5 && state.backoff_nonzero[order - 1].any)
            std::cout << " bow=[" << state.backoff_nonzero[order - 1].minimum << ","
                      << state.backoff_nonzero[order - 1].maximum << "]";
        std::cout << "\n";
    }
    for (int order = 2; order <= 5; ++order)
        std::cout << "order" << order << " blocks=" << header.sections[order - 2].block_count
                  << "\n";
    fs::remove_all(temp);
}

int main(int argc, char** argv) {
    try {
        if (argc != 4)
            throw std::runtime_error("usage: build_tcs_knm03 input.arpa output.bin temp-dir");
        build_model(fs::absolute(argv[1]), fs::absolute(argv[2]), fs::absolute(argv[3]));
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "build_tcs_knm03: " << error.what() << "\n";
        return 1;
    }
}
