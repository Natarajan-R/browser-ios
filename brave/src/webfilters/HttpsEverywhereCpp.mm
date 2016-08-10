/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */
#include "HttpsEverywhereCpp.h"

#include <sqlite3.h>
#include <string>
#include <vector>
#include <sstream>
#include <regex>
#include "JsonCpp.h"

using json = nlohmann::json;

sqlite3 *httpse_db_ = 0;
std::string dbFilePath;

int SQLITEIdsCallback(void *a_param, int argc, char **argv, char **column) {
    if (argc <= 0 || nullptr == argv) {
        return 0;
    }
    std::string* ruleIds = (std::string*)a_param;
    if (0 != ruleIds->length()) {
        *ruleIds += ",";
    }
    std::string toInsert(argv[0]);
    if (toInsert.length() >= 2 && toInsert[0] == '[' && toInsert[toInsert.length() - 1] == ']') {
        toInsert.erase(0, 1);
        toInsert.erase(toInsert.length() - 1);
    }
    *ruleIds += toInsert;

    return 0;
}

int SQLITECallback(void *a_param, int argc, char **argv, char **column) {
    if (argc <= 0 || nullptr == argv) {
        return 0;
    }
    std::vector<std::string>* rules = (std::vector<std::string>*)a_param;
    rules->push_back(argv[0]);

    return 0;
}

bool InitHTTPSE() {
    // Init sqlite database

    int err = sqlite3_open(dbFilePath.c_str(), &httpse_db_);
    if (err != SQLITE_OK) {
        // std::cout << "sqlite db open error " << dbFilePath.c_str() << ", err == " << err;
        return false;
    }

    return true;
}

std::string applyHTTPSRule(const std::string& originalUrl, const std::string& rule) {
    auto json_object = json::parse(rule);
    if (json_object.is_null()) {
        return "";
    }

    auto obj = json_object["ruleset"]["$"];
    if (obj.is_null()) {
        return "";
    }

    if (!obj["default_off"].is_null() || !obj["platform"].is_null()) {
        return "";
    }

    // Check on exclusions
    auto rs = json_object["ruleset"];
    if (rs.is_null()) {
        return "";
    }
    auto excl = rs["exclusion"];
    if (!excl.is_null() && excl.is_array()) {
        std::vector<json> v = excl;
        for (auto item : v) {
            if (!item["$"].is_null()) {
                std::string pattern = item["$"]["pattern"];
                if (std::regex_match(originalUrl, std::regex(pattern))) {
                    return "";
                }
            }
        }
    }

    auto rules = rs["rule"];
    if (rules.is_null() || !rules.is_array()) {
        return "";
    }

    std::vector<json> v = rules;
    for (auto item : v) {
        auto root = item["$"];
        if (root.is_null()) {
            continue;
        }
        auto from = root["from"];
        auto to = root["to"];
        if (!from.is_null() && !to.is_null()) {
            std::string f = from;
            std::string t = to;
            std::string result = std::regex_replace(originalUrl, std::regex(f), t);
            if (strncmp(result.c_str(), "https", strlen("https")) == 0) {
                return result;
            }
        }
    }

    return "";
}

std::string getHTTPSNewHostFromIds(const std::string& ruleIds, const std::string& originalUrl) {
    if (nullptr == httpse_db_) {
        return "";
    }

    std::vector<std::string> rules;
    std::string query("select contents from rulesets where id in (" + ruleIds + ")");
    char *err = NULL;
    if (SQLITE_OK != sqlite3_exec(httpse_db_, query.c_str(), SQLITECallback, &rules, &err)) {
        std::cout << "sqlite exec error: " << err;
        sqlite3_free(err);

        return "";
    }

    for (int i = 0; i < (int)rules.size(); i++) {
        std::string newUrl(applyHTTPSRule(originalUrl, rules[i]));
        if (0 != newUrl.length()) {
            return newUrl;
        }
    }

    return "";
}


void xProfile(void *pArg, const char *pQuery, sqlite3_uint64 pTimeTaken)
{
    printf("%s, ", pQuery);
    printf("%llu ms \n", pTimeTaken / 1000000);
}


// return empty string if no result
std::string getHTTPSURL(const std::string &urlHost, const std::string &urlPath) {
    if (nullptr == httpse_db_ && !InitHTTPSE()) {
        return "";
    }

    std::istringstream host(urlHost);
    std::vector<std::string> domains;
    std::string domain;
    while (std::getline(host, domain, '.')) {
        domains.push_back(domain);
    }
    if (domains.size() <= 1) {
        return "";
    }

    std::string query = "select ids from targets where host like '";
    std::string domain_to_check(domains[domains.size() - 1]);
    for (int i = (int)domains.size() - 2; i >= 0; i--) {
        if (i != (int)domains.size() - 2) {
            query += " or host like '";
        }
        domain_to_check.insert(0, ".");
        domain_to_check.insert(0, domains[i]);
        std::string prefix;
        if (i > 0) {
            prefix = "*.";
        }
        query += prefix + domain_to_check + "'";
    }

    sqlite3_profile(httpse_db_, xProfile, NULL);

    char *err = NULL;
    std::string ruleIds;
    if (SQLITE_OK != sqlite3_exec(httpse_db_, query.c_str(), SQLITEIdsCallback, &ruleIds, &err)) {
        std::cout << "sqlite exec ids error: " << err;
        sqlite3_free(err);

        return "";
    }

    if (0 == ruleIds.length()) {
        return "";
    }
    std::string fullURL = urlPath.length() > 0 ? urlHost + urlPath : urlHost + "/";
    std::string newURL = getHTTPSNewHostFromIds(ruleIds, "http://" + fullURL);
    if (0 != newURL.length()) {
        return newURL;
    }

    return "";
}

// ** Obj-C Interface **//

@implementation HttpEverywhereCpp

-(void)setDataFile:(NSString* )path
{
    dbFilePath = [path UTF8String];
    InitHTTPSE();
}

-(BOOL)hasDataFile
{
    return httpse_db_ != nil;
}

- (NSString *)tryRedirectingUrl:(NSURL *)url
{
    @synchronized(self) {
        NSString *host = url.host;
        NSString *path = [url.absoluteString stringByReplacingOccurrencesOfString:[@"http://" stringByAppendingString:host]
                                                      withString:@""];
        if (path.length < 1) {
            path = @"/";
        }
        std::string result = getHTTPSURL(host ? host.UTF8String : "" , path ? path.UTF8String : "");
        return [NSString stringWithUTF8String:result.c_str()];
    }
}

@end

