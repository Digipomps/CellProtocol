// SPDX-License-Identifier: Apache-2.0
// S0 feasibility probe, not a production formatter adapter. One process per
// message; all arguments are passed by name through ICU's supported C++ API.
#include <unicode/msgfmt.h>
#include <unicode/datefmt.h>
#include <unicode/timezone.h>
#include <unicode/uversion.h>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

int main(int argc, char **argv) {
    if (argc < 4 || (argc - 4) % 3 != 0) return 2;
    UErrorCode status = U_ZERO_ERROR;
    auto locale = icu::Locale::forLanguageTag(argv[2], status);
    icu::MessageFormat formatter(icu::UnicodeString::fromUTF8(argv[1]), locale, status);
    std::vector<icu::UnicodeString> names;
    std::vector<icu::Formattable> values;
    for (int i = 4; i < argc; i += 3) {
        names.emplace_back(icu::UnicodeString::fromUTF8(argv[i]));
        std::string type(argv[i + 1]);
        if (type == "integer") values.emplace_back(static_cast<int64_t>(std::stoll(argv[i + 2])));
        else if (type == "number") values.emplace_back(std::stod(argv[i + 2]));
        else if (type == "date") {
            values.emplace_back(std::stod(argv[i + 2]), icu::Formattable::kIsDate);
            auto current = formatter.getFormat(names.back(), status);
            if (auto dateFormat = dynamic_cast<const icu::DateFormat *>(current)) {
                std::unique_ptr<icu::DateFormat> localized(dateFormat->clone());
                std::unique_ptr<icu::TimeZone> zone(icu::TimeZone::createTimeZone(icu::UnicodeString::fromUTF8(argv[3])));
                localized->setTimeZone(*zone);
                formatter.setFormat(names.back(), *localized, status);
            }
        } else values.emplace_back(icu::UnicodeString::fromUTF8(argv[i + 2]));
    }
    icu::UnicodeString output;
    formatter.format(names.data(), values.data(), static_cast<int32_t>(values.size()), output, status);
    if (U_FAILURE(status)) { std::cerr << u_errorName(status); return 1; }
    std::string utf8;
    output.toUTF8String(utf8);
    std::cout << utf8;
    return 0;
}
