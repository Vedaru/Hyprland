#include "../../hyprctlCompat.hpp"
#include "../../shared.hpp"
#include "../shared.hpp"
#include "build.hpp"
#include "tests.hpp"

#include <array>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstring>
#include <format>
#include <hyprutils/os/FileDescriptor.hpp>
#include <hyprutils/os/Process.hpp>
#include <hyprutils/utils/ScopeGuard.hpp>
#include <optional>
#include <stdexcept>
#include <string>
#include <sys/poll.h>
#include <thread>
#include <unistd.h>
#include <vector>

using namespace Hyprutils::Memory;
using namespace Hyprutils::OS;
using namespace Hyprutils::Utils;

#define SP CSharedPointer

// A window that covers the whole output should be promoted to internal fullscreen when the output
// has reserved zones (e.g. a bar at the top), because the layout can otherwise only give it the
// work area. Two protocol-level ways of asking for it are covered:
//   - the client declares via set_min_size that it cannot be smaller than the output,
//   - the client renders at the output size without declaring any size hint.
// Neither keys off class, title or executable: any client doing either behaves the same.
namespace {
    class CClient {
      public:
        explicit CClient(const std::vector<std::string>& args);
        ~CClient();

        std::string command(const std::string& command);

      private:
        SP<CProcess>           m_proc;
        std::array<char, 2048> m_readBuf;
        CFileDescriptor        m_readFd, m_writeFd;
        struct pollfd          m_fds = {};
    };
}

static bool waitForClientWindow(pid_t pid, int timeoutMs) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
    const auto needle   = std::format("pid: {}", pid);

    while (Tests::processAlive(pid)) {
        if (getFromSocket("/clients").contains(needle))
            return true;

        if (std::chrono::steady_clock::now() >= deadline)
            return false;
    }

    return false;
}

CClient::CClient(const std::vector<std::string>& args) {
    m_proc = makeShared<CProcess>(binaryDir + "/whole-output", args);
    m_proc->addEnv("WAYLAND_DISPLAY", WLDISPLAY);

    int pipeFds1[2], pipeFds2[2];
    if (pipe(pipeFds1) != 0 || pipe(pipeFds2) != 0)
        throw std::runtime_error(std::format("pipe failed: {}", strerror(errno)));

    m_writeFd = CFileDescriptor(pipeFds1[1]);
    m_proc->setStdinFD(pipeFds1[0]);

    m_readFd = CFileDescriptor(pipeFds2[0]);
    m_proc->setStdoutFD(pipeFds2[1]);

    m_proc->runAsync();

    close(pipeFds1[0]);
    close(pipeFds2[1]);

    m_fds         = {.fd = m_readFd.get(), .events = POLLIN};
    m_fds.revents = 0;
    int pollRet   = 0;
    do {
        pollRet = poll(&m_fds, 1, 30000);
    } while (pollRet == -1 && errno == EINTR);

    if (pollRet != 1 || !(m_fds.revents & POLLIN))
        throw std::runtime_error(
            std::format("startup stdout poll failed: ret={} revents={} alive={} pid={}", pollRet, m_fds.revents, Tests::processAlive(m_proc->pid()), m_proc->pid()));

    m_readBuf.fill(0);
    const ssize_t bytesRead = read(m_readFd.get(), m_readBuf.data(), m_readBuf.size() - 1);
    if (bytesRead <= 0)
        throw std::runtime_error(std::format("startup stdout read failed: bytes={} errno={} ({})", bytesRead, errno, strerror(errno)));

    const std::string ret = std::string{m_readBuf.data()};
    if (!ret.contains("started"))
        throw std::runtime_error(std::format("client reported '{}'", ret));

    if (!waitForClientWindow(m_proc->pid(), 10000))
        throw std::runtime_error(std::format("window did not appear for pid {}", m_proc->pid()));
}

CClient::~CClient() {
    const std::string cmd = "exit\n";
    write(m_writeFd.get(), cmd.c_str(), cmd.length());

    if (m_proc)
        kill(m_proc->pid(), SIGKILL);
}

std::string CClient::command(const std::string& command) {
    const std::string cmd = command + "\n";
    if ((size_t)write(m_writeFd.get(), cmd.c_str(), cmd.length()) != cmd.length())
        return "";

    m_fds.revents = 0;
    if (poll(&m_fds, 1, 10000) != 1 || !(m_fds.revents & POLLIN))
        return "";

    const ssize_t bytesRead = read(m_fds.fd, m_readBuf.data(), m_readBuf.size() - 1);
    if (bytesRead <= 0)
        return "";

    m_readBuf[bytesRead] = 0;
    std::string ret      = std::string{m_readBuf.data()};
    if (!ret.empty() && ret.back() == '\n')
        ret.pop_back();
    return ret;
}

// HEADLESS-2 is declared by test.lua as 1920x1080 at scale 1, so "the whole output" is exactly
// 1920x1080. Only the reserved area is touched here; overriding mode/position would move the
// output (and with it the workspace the test relies on) rather than just testing the promotion.
static std::string reservedCmd(int reserved) {
    const std::string SIDES = std::format("top = {}, right = {}, bottom = {}, left = {}", reserved, reserved, reserved, reserved);
    return std::format("hl.monitor({{ output = 'HEADLESS-2', reserved = {{ {} }} }})", SIDES);
}

// hl.monitor() only queues a monitor rule change; the reserved area reaches the live monitor on
// the compositor's next reconfigure, not synchronously with the eval. Wait for it to land, or the
// client can map while the output still has no reserved zones and the promotion has nothing to
// protect. /monitors reports the live area, so it is the synchronization point.
static bool waitForReserved(int reserved) {
    const std::string WANTED = std::format("reserved: {} {} {} {}", reserved, reserved, reserved, reserved);
    for (int i = 0; i < 100; i++) {
        if (getFromSocket("/monitors").contains(WANTED))
            return true;

        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    return false;
}

static void killTestWindows() {
    Tests::killAllWindows();
    Tests::waitUntilWindowsN(0);
}

// Waits until the (only) window reports the given property, so a test doesn't race the layout pass
// that follows a map.
static std::string waitForActiveProp(const std::string& needle, int maxTries = 50) {
    std::string ret;
    for (int i = 0; i < maxTries; i++) {
        ret = getFromSocket("/activewindow");
        if (ret.contains(needle))
            return ret;

        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    return ret;
}

TEST_CASE(wholeOutput) {
    const auto applyReserved = [&](int reserved) {
        OK(getFromSocket("/eval " + reservedCmd(reserved)));
        if (!waitForReserved(reserved))
            FAIL_TEST("reserved area never became '{} {} {} {}'", reserved, reserved, reserved, reserved);
    };

    CScopeGuard guard = {[&]() {
        applyReserved(0);
        killTestWindows();
    }};

    applyReserved(0);
    OK(getFromSocket("/dispatch hl.dsp.focus({ monitor = 'HEADLESS-2' })"));
    OK(getFromSocket("/dispatch hl.dsp.focus({ workspace = '300' })"));

    // A client that declares it cannot be smaller than the whole output is promoted to internal
    // fullscreen, so it covers the reserved zones instead of overflowing the work area.
    applyReserved(200);
    {
        std::optional<CClient> client;
        try {
            client.emplace(std::vector<std::string>{"--min", "1920", "1080"});
        } catch (const std::exception& e) { FAIL_TEST("Couldn't start the whole-output client: {}", e.what()); }

        Tests::sync();
        const auto PROPS = waitForActiveProp("fullscreen: 2");
        EXPECT_CONTAINS(PROPS, "fullscreen: 2");
        EXPECT_CONTAINS(PROPS, "fullscreenClient: 2");
        EXPECT_CONTAINS(PROPS, "at: 0,0");
        EXPECT_CONTAINS(PROPS, "size: 1920,1080");

        // The client dropping its own fullscreen state must not drop the promotion: it still cannot
        // be smaller than the output, so it keeps covering it, just without the client-side state.
        ASSERT(client->command("fullscreen"), "ok");
        ASSERT(client->command("unfullscreen"), "ok");
        const auto AFTER_UNFS = waitForActiveProp("fullscreenClient: 0");
        EXPECT_CONTAINS(AFTER_UNFS, "fullscreen: 2");
        EXPECT_CONTAINS(AFTER_UNFS, "fullscreenClient: 0");
        EXPECT_CONTAINS(AFTER_UNFS, "at: 0,0");
        EXPECT_CONTAINS(AFTER_UNFS, "size: 1920,1080");
    }
    killTestWindows();

    // A client that starts fullscreen before mapping, then drops it, is the shape games in a
    // borderless "windowed fullscreen" mode have: the pre-map fullscreen request cannot be judged
    // by the map-time promotion (the window does not exist yet), so once the client lets go of its
    // own state the window falls back to the layout. Because it renders at the whole output and
    // only fixes one axis as its minimum (enough for Hyprland to auto-float it), that fallback is a
    // floating window at output size overflowing the work area. It must keep covering the output.
    {
        std::optional<CClient> client;
        try {
            client.emplace(std::vector<std::string>{"--hint", "1920", "720", "1920", "2400", "--size", "1920", "1080", "--initial-fs"});
        } catch (const std::exception& e) { FAIL_TEST("Couldn't start the whole-output client: {}", e.what()); }

        Tests::sync();
        const auto FS = waitForActiveProp("fullscreenClient: 2");
        EXPECT_CONTAINS(FS, "fullscreen: 2");
        EXPECT_CONTAINS(FS, "fullscreenClient: 2");

        ASSERT(client->command("unfullscreen"), "ok");
        const auto AFTER_UNFS = waitForActiveProp("fullscreenClient: 0");
        EXPECT_CONTAINS(AFTER_UNFS, "fullscreen: 2");
        EXPECT_CONTAINS(AFTER_UNFS, "fullscreenClient: 0");
        EXPECT_CONTAINS(AFTER_UNFS, "at: 0,0");
        EXPECT_CONTAINS(AFTER_UNFS, "size: 1920,1080");
    }
    killTestWindows();

    // A client that asks to be smaller than the output is left to the layout.
    {
        std::optional<CClient> client;
        try {
            client.emplace(std::vector<std::string>{"--min", "1280", "720"});
        } catch (const std::exception& e) { FAIL_TEST("Couldn't start the whole-output client: {}", e.what()); }

        Tests::sync();
        const auto PROPS = getFromSocket("/activewindow");
        EXPECT_CONTAINS(PROPS, "fullscreen: 0");
        EXPECT_NOT_CONTAINS(PROPS, "size: 1920,1080");
    }
    killTestWindows();

    // A client that renders at the whole output without declaring a size hint gets the same
    // treatment: the reserved zones leave the layout unable to give it that size.
    {
        std::optional<CClient> client;
        try {
            client.emplace(std::vector<std::string>{"--size", "1920", "1080"});
        } catch (const std::exception& e) { FAIL_TEST("Couldn't start the whole-output client: {}", e.what()); }

        Tests::sync();
        const auto PROPS = waitForActiveProp("fullscreen: 2");
        EXPECT_CONTAINS(PROPS, "fullscreen: 2");
        EXPECT_CONTAINS(PROPS, "fullscreenClient: 2");
        EXPECT_CONTAINS(PROPS, "at: 0,0");
        EXPECT_CONTAINS(PROPS, "size: 1920,1080");
    }
    killTestWindows();

    // Without reserved zones there is nothing to protect: the layout can already give the window
    // the whole output, so neither trigger fires and ordinary tiling is untouched.
    applyReserved(0);
    {
        std::optional<CClient> client;
        try {
            client.emplace(std::vector<std::string>{"--size", "1920", "1080"});
        } catch (const std::exception& e) { FAIL_TEST("Couldn't start the whole-output client: {}", e.what()); }

        Tests::sync();
        EXPECT_CONTAINS(getFromSocket("/activewindow"), "fullscreen: 0");
    }
    killTestWindows();

    {
        std::optional<CClient> client;
        try {
            client.emplace(std::vector<std::string>{"--min", "1920", "1080"});
        } catch (const std::exception& e) { FAIL_TEST("Couldn't start the whole-output client: {}", e.what()); }

        Tests::sync();
        EXPECT_CONTAINS(getFromSocket("/activewindow"), "fullscreen: 0");
    }
    killTestWindows();
}

// The float heuristic for native toplevels keys off the client's own protocol state, so it is
// exercised through the same client: one axis fixed must stay tileable, both axes fixed must
// float, and a declared parent must float.
TEST_CASE(toplevelFloat) {
    CScopeGuard guard = {[&]() {
        getFromSocket("/eval " + reservedCmd(0));
        killTestWindows();
    }};

    OK(getFromSocket("/eval " + reservedCmd(0)));
    OK(getFromSocket("/dispatch hl.dsp.focus({ monitor = 'HEADLESS-2' })"));

    // Only one axis is fixed: the layout can still resize the other one, so the window is tiled.
    // The max must still span the output, otherwise the tiling algorithm floats it first (its own
    // "max size smaller than the tile" bail-out) and shouldBeFloated() never gets a say.
    {
        std::optional<CClient> client;
        try {
            client.emplace(std::vector<std::string>{"--hint", "1920", "300", "1920", "2400"});
        } catch (const std::exception& e) { FAIL_TEST("Couldn't start the toplevel client: {}", e.what()); }

        Tests::sync();
        EXPECT_CONTAINS(getFromSocket("/activewindow"), "floating: 0");
    }
    killTestWindows();

    // Both axes are fixed, leaving the layout no axis to resize: the window is floated.
    {
        std::optional<CClient> client;
        try {
            client.emplace(std::vector<std::string>{"--hint", "400", "300", "400", "300"});
        } catch (const std::exception& e) { FAIL_TEST("Couldn't start the toplevel client: {}", e.what()); }

        Tests::sync();
        EXPECT_CONTAINS(waitForActiveProp("floating: 1"), "floating: 1");
    }
    killTestWindows();

    // A declared parent makes the window transient/dialog-like, so it floats regardless of hints.
    {
        std::optional<CClient> client;
        try {
            client.emplace(std::vector<std::string>{"--parent"});
        } catch (const std::exception& e) { FAIL_TEST("Couldn't start the toplevel client: {}", e.what()); }

        Tests::sync();
        EXPECT_CONTAINS(waitForActiveProp("floating: 1"), "floating: 1");
    }
    killTestWindows();
}
