"""Validate shared-bank ownership using LÖVE's native classes on the host.

python tests/vita_audio_bank_native_test.py [--love-src /path/to/love/src]
This checks FileData/DataView/Variant lifetime across a real host thread, not
Vita execution or the complete LÖVE Lua/Channel runtime.
"""
import argparse
import json
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = r'''
#include "modules/filesystem/FileData.h"
#include "modules/data/DataView.h"
#include "common/Variant.h"
#include <cassert>
#include <cstring>
#include <thread>
#include <future>
#include <sys/resource.h>
#include <cstdio>
using love::filesystem::FileData;
using love::data::DataView;
static int destroyed = 0;
struct Bank : FileData {
    Bank(size_t n) : FileData(n, "samples.bin") {}
    ~Bank() { destroyed++; }
};
int main(int argc, char **argv) {
    const bool shared = argc == 2 && std::strcmp(argv[1], "shared") == 0;
    const size_t n = 16 * 1024 * 1024;
    auto *mainbank = new Bank(n);
    auto *bytes = static_cast<unsigned char *>(mainbank->getData());
    for (size_t i = 0; i < n; i++) bytes[i] = (i * 37 + i / 251) & 255;
    FileData *workerbank = shared ? mainbank : new FileData(*mainbank);
    std::promise<void> ownerReleased;
    auto ready = ownerReleased.get_future();
    {
        love::Variant sent(&FileData::type, workerbank);
        // Variant copies are how LOVE Channel messages retain a Data object.
        std::thread worker([workerbank, sent, &ready]() {
            ready.wait();
            for (size_t k = 0; k < 128; k++) {
                size_t offset = (k * 7919) % (workerbank->getSize() - 8192);
                auto *view = new DataView(workerbank, offset, 8192);
                assert(view->getData() == static_cast<char *>(workerbank->getData()) + offset);
                std::string pcm(static_cast<char *>(view->getData()), view->getSize());
                view->release();
                for (size_t i = 0; i < pcm.size(); i++)
                    assert(static_cast<unsigned char>(pcm[i]) == (((i+offset)*37 + (i+offset)/251) & 255));
            }
            bool rejected = false;
            try { auto *bad = new DataView(workerbank, workerbank->getSize()-1, 2); bad->release(); }
            catch (...) { rejected = true; }
            assert(rejected);
        });
        sent = love::Variant(); // The sender/channel no longer retains it.
        if (!shared) workerbank->release();
        mainbank->release(); // The owner goes away before the receiver reads.
        assert(destroyed == (shared ? 0 : 1)); // receiver is now the sole owner
        ownerReleased.set_value();
        worker.join();
        assert(destroyed == 1);
    }
    assert(destroyed == 1);
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    std::printf("{\"mode\":\"%s\",\"bankBytes\":%zu,\"peakRssKiB\":%ld}\n",
        shared ? "shared" : "copied", n * (shared ? 1 : 2), usage.ru_maxrss);
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--love-src", type=pathlib.Path,
                        default=ROOT / "mobile/android/love/src/jni/love/src")
    args = parser.parse_args()
    src = args.love_src.resolve()
    lua = ROOT / "mobile/android/love/src/jni/LuaJIT-2.1/src"
    files = ["common/Object.cpp", "common/Data.cpp", "common/types.cpp",
             "common/Exception.cpp", "common/Variant.cpp",
             "modules/filesystem/FileData.cpp", "modules/data/DataView.cpp"]
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        (work / "bank.cpp").write_text(SOURCE)
        subprocess.run(["c++", "-std=c++14", "-O2", "-pthread", "-ffunction-sections",
                        "-fdata-sections", "-Wl,--gc-sections", "-I"+str(src),
                        "-I"+str(lua), str(work / "bank.cpp"),
                        *[str(src / path) for path in files], "-o", str(work / "bank")], check=True)
        results = [json.loads(subprocess.check_output([str(work / "bank"), mode], text=True))
                   for mode in ("copied", "shared")]
        assert results[0]["bankBytes"] == results[1]["bankBytes"] * 2
        print(json.dumps({"source": str(src), "results": results,
                          "savedBankBytes": results[1]["bankBytes"]}))


if __name__ == "__main__":
    main()
