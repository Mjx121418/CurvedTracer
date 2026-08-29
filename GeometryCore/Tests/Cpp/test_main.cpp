#include "test_framework.h"

int g_checks = 0;
int g_failures = 0;
std::vector<std::string> g_failmsgs;

int main() {
    test_math();
    test_stereo();
    test_geodesic();
    test_isometry();
    test_intersect();
    test_atlas();

    if (g_failures == 0) {
        std::printf("OK: %d checks passed\n", g_checks);
        return 0;
    }
    std::printf("FAILED: %d / %d checks failed\n", g_failures, g_checks);
    for (const auto& m : g_failmsgs)
        std::printf("  %s\n", m.c_str());
    return 1;
}
