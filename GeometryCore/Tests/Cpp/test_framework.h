#pragma once
// Minimal dependency-free test framework.
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

extern int g_checks;
extern int g_failures;
extern std::vector<std::string> g_failmsgs;

#define CHECK(cond)                                                                                \
    do {                                                                                           \
        ++g_checks;                                                                                \
        if (!(cond)) {                                                                             \
            ++g_failures;                                                                          \
            g_failmsgs.push_back(std::string(__FILE__) + ":" + std::to_string(__LINE__) +          \
                                 " CHECK failed: " + #cond);                                       \
        }                                                                                          \
    } while (0)

#define CHECK_NEAR(a, b, tol)                                                                      \
    do {                                                                                           \
        ++g_checks;                                                                                \
        double _a = (a), _b = (b);                                                                 \
        if (std::fabs(_a - _b) > (tol)) {                                                          \
            ++g_failures;                                                                          \
            char _buf[256];                                                                        \
            std::snprintf(_buf, sizeof _buf, "%s:%d CHECK_NEAR failed: %s=%g vs %s=%g (tol %g)",   \
                          __FILE__, __LINE__, #a, _a, #b, _b, (double)(tol));                      \
            g_failmsgs.push_back(_buf);                                                            \
        }                                                                                          \
    } while (0)

// test suites (each translation unit defines its own)
void test_math();
void test_stereo();
void test_isometry();
void test_intersect();
void test_atlas();
