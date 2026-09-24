// Test client for the "wants to cover the whole output" promotion.
//
// Creates a single xdg_toplevel and lets the test toggle its own fullscreen state over stdin.
// Two ways of asking to cover the output:
//   --min W H   advertises a minimum size via xdg_toplevel.set_min_size (and the same maximum),
//               i.e. declares that it cannot be smaller than the whole output.
//   --size W H  ignores the size the compositor configures it at and keeps rendering at WxH,
//               without advertising any size hint at all.
//   --parent    declares a (never mapped) parent toplevel, i.e. is a child/transient window.
// Either way the compositor is expected to keep the window covering the whole output, including
// zones reserved at the edges, even after the client drops its own fullscreen state.
#include <print>
#include <poll.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>

#include <wayland-client.h>
#include <wayland.hpp>
#include <xdg-shell.hpp>

#include <hyprutils/memory/SharedPtr.hpp>
#include <hyprutils/math/Vector2D.hpp>

#include <algorithm>
#include <array>
#include <string>
#include <utility>

using Hyprutils::Math::Vector2D;
using namespace Hyprutils::Memory;

struct SWlState {
    wl_display*                    display;
    CSharedPointer<CCWlRegistry>   registry;

    CSharedPointer<CCWlCompositor> wlCompositor;
    CSharedPointer<CCWlSeat>       wlSeat;
    CSharedPointer<CCWlShm>        wlShm;
    CSharedPointer<CCXdgWmBase>    xdgShell;

    CSharedPointer<CCWlShmPool>    shmPool;
    CSharedPointer<CCWlBuffer>     shmBuf;
    int                            shmFd            = 0;
    size_t                         shmBufSize       = 0;
    bool                           xrgb8888_support = false;

    CSharedPointer<CCWlSurface>    surf;
    CSharedPointer<CCXdgSurface>   xdgSurf;
    CSharedPointer<CCXdgToplevel>  xdgToplevel;

    // A dummy parent toplevel: only used to declare the main window as a transient/dialog-like
    // child, which Hyprland floats. It is never mapped or committed.
    bool                          wantsParent = false;
    CSharedPointer<CCWlSurface>   parentSurf;
    CSharedPointer<CCXdgSurface>  parentXdgSurf;
    CSharedPointer<CCXdgToplevel> parentToplevel;

    Vector2D                      minSize = {0, 0};
    Vector2D                      maxSize = {0, 0};
    // When set, the client ignores the size the compositor configures it at and keeps rendering
    // at this size, without advertising any size hint. That is a borderless "windowed fullscreen"
    // client that covers the output by accident of its own geometry rather than by declaring it.
    Vector2D forceSize = {0, 0};
    // Requests fullscreen before mapping, like a game that starts fullscreen. The request reaches
    // the compositor before the window exists, so it cannot be re-judged by the map-time promotion.
    bool     initialFS = false;
    Vector2D geom;
};

static bool debug, shouldExit, started;

template <typename... Args>
//NOLINTNEXTLINE
static void clientLog(std::format_string<Args...> fmt, Args&&... args) {
    std::string text = std::format(fmt, std::forward<Args>(args)...);
    std::println("{}", text);
    std::fflush(stdout);
}

template <typename... Args>
//NOLINTNEXTLINE
static void debugLog(std::format_string<Args...> fmt, Args&&... args) {
    if (!debug)
        return;

    std::string text = std::format(fmt, std::forward<Args>(args)...);
    std::println("{}", text);
    std::fflush(stdout);
}

static bool bindRegistry(SWlState& state) {
    state.registry = makeShared<CCWlRegistry>((wl_proxy*)wl_display_get_registry(state.display));

    state.registry->setGlobal([&](CCWlRegistry* r, uint32_t id, const char* name, uint32_t version) {
        const std::string NAME = name;
        if (NAME == "wl_compositor")
            state.wlCompositor = makeShared<CCWlCompositor>((wl_proxy*)wl_registry_bind((wl_registry*)state.registry->resource(), id, &wl_compositor_interface, 6));
        else if (NAME == "wl_shm")
            state.wlShm = makeShared<CCWlShm>((wl_proxy*)wl_registry_bind((wl_registry*)state.registry->resource(), id, &wl_shm_interface, 1));
        else if (NAME == "wl_seat")
            state.wlSeat = makeShared<CCWlSeat>((wl_proxy*)wl_registry_bind((wl_registry*)state.registry->resource(), id, &wl_seat_interface, 9));
        else if (NAME == "xdg_wm_base")
            state.xdgShell = makeShared<CCXdgWmBase>((wl_proxy*)wl_registry_bind((wl_registry*)state.registry->resource(), id, &xdg_wm_base_interface, 1));
    });

    wl_display_roundtrip(state.display);

    if (!state.wlCompositor || !state.wlShm || !state.wlSeat || !state.xdgShell) {
        clientLog("Failed to get protocols from Hyprland");
        return false;
    }

    return true;
}

static bool createShm(SWlState& state, Vector2D geom) {
    if (!state.xrgb8888_support || geom.x < 1 || geom.y < 1)
        return false;

    const size_t STRIDE = geom.x * 4;
    const size_t SIZE   = geom.y * STRIDE;

    if (!state.shmPool) {
        state.shmFd = shm_open("/wl-shm-whole-output", O_RDWR | O_CREAT | O_EXCL, 0600);
        if (state.shmFd < 0)
            return false;

        if (shm_unlink("/wl-shm-whole-output") < 0 || ftruncate(state.shmFd, SIZE) < 0) {
            close(state.shmFd);
            state.shmFd = -1;
            return false;
        }

        state.shmPool = makeShared<CCWlShmPool>(state.wlShm->sendCreatePool(state.shmFd, SIZE));
        if (!state.shmPool->resource()) {
            close(state.shmFd);
            state.shmFd = -1;
            state.shmPool.reset();
            return false;
        }

        state.shmBufSize = SIZE;
    } else if (SIZE > state.shmBufSize) {
        if (ftruncate(state.shmFd, SIZE) < 0)
            return false;

        state.shmPool->sendResize(SIZE);
        state.shmBufSize = SIZE;
    }

    auto buf = makeShared<CCWlBuffer>(state.shmPool->sendCreateBuffer(0, geom.x, geom.y, STRIDE, WL_SHM_FORMAT_XRGB8888));
    if (!buf->resource())
        return false;

    if (state.shmBuf) {
        state.shmBuf->sendDestroy();
        state.shmBuf.reset();
    }
    state.shmBuf = buf;

    return true;
}

static bool setupToplevel(SWlState& state) {
    state.wlShm->setFormat([&](CCWlShm* p, uint32_t format) {
        if (format == WL_SHM_FORMAT_XRGB8888)
            state.xrgb8888_support = true;
    });

    state.xdgShell->setPing([&](CCXdgWmBase* p, uint32_t serial) { state.xdgShell->sendPong(serial); });

    state.surf = makeShared<CCWlSurface>(state.wlCompositor->sendCreateSurface());
    if (!state.surf->resource())
        return false;

    state.xdgSurf = makeShared<CCXdgSurface>(state.xdgShell->sendGetXdgSurface(state.surf->resource()));
    if (!state.xdgSurf->resource())
        return false;

    state.xdgToplevel = makeShared<CCXdgToplevel>(state.xdgSurf->sendGetToplevel());
    if (!state.xdgToplevel->resource())
        return false;

    state.xdgToplevel->setClose([&](CCXdgToplevel* p) { exit(0); });

    // A client that insists on a minimum size renders at least that large, so the compositor
    // sees a geometry that matches the hint.
    state.xdgToplevel->setConfigure([&](CCXdgToplevel* p, int32_t w, int32_t h, wl_array* arr) {
        const int32_t W = state.forceSize.x > 0 ? state.forceSize.x : std::max<int32_t>(w > 0 ? w : 1280, state.minSize.x);
        const int32_t H = state.forceSize.y > 0 ? state.forceSize.y : std::max<int32_t>(h > 0 ? h : 720, state.minSize.y);

        state.geom = {W, H};

        if (!createShm(state, state.geom))
            exit(-1);
    });

    state.xdgSurf->setConfigure([&](CCXdgSurface* p, uint32_t serial) {
        if (!state.shmBuf)
            debugLog("xdgSurf configure but no buffer yet");

        state.xdgSurf->sendSetWindowGeometry(0, 0, state.geom.x, state.geom.y);
        state.surf->sendAttach(state.shmBuf.get(), 0, 0);
        state.surf->sendCommit();

        state.xdgSurf->sendAckConfigure(serial);

        if (!started) {
            started = true;
            clientLog("started");
        }
    });

    state.xdgToplevel->sendSetTitle("whole-output-test");
    state.xdgToplevel->sendSetAppId("whole-output-test");

    if (state.wantsParent) {
        state.parentSurf = makeShared<CCWlSurface>(state.wlCompositor->sendCreateSurface());
        if (!state.parentSurf->resource())
            return false;

        state.parentXdgSurf = makeShared<CCXdgSurface>(state.xdgShell->sendGetXdgSurface(state.parentSurf->resource()));
        if (!state.parentXdgSurf->resource())
            return false;

        state.parentToplevel = makeShared<CCXdgToplevel>(state.parentXdgSurf->sendGetToplevel());
        if (!state.parentToplevel->resource())
            return false;

        state.parentToplevel->sendSetTitle("whole-output-test-parent");
        state.parentToplevel->sendSetAppId("whole-output-test");

        // Declaring a parent is enough to be treated as a child window; the parent surface itself
        // never has to be mapped or committed.
        state.xdgToplevel->sendSetParent(state.parentToplevel.get());
    }

    if (state.minSize.x > 0 && state.minSize.y > 0) {
        state.xdgToplevel->sendSetMinSize(state.minSize.x, state.minSize.y);
        state.xdgToplevel->sendSetMaxSize(state.maxSize.x > 0 ? state.maxSize.x : state.minSize.x, state.maxSize.y > 0 ? state.maxSize.y : state.minSize.y);
    }

    if (state.initialFS)
        state.xdgToplevel->sendSetFullscreen(nullptr);

    state.surf->sendAttach(nullptr, 0, 0);
    state.surf->sendCommit();

    return true;
}

static void parseRequest(SWlState& state, std::string str) {
    const size_t INDEX = str.find_first_of('\n');
    str                = str.substr(0, INDEX);

    if (str == "exit")
        shouldExit = true;
    else if (str == "fullscreen")
        state.xdgToplevel->sendSetFullscreen(nullptr);
    else if (str == "unfullscreen")
        state.xdgToplevel->sendUnsetFullscreen();
    else
        return;

    clientLog("ok");
}

int main(int argc, char** argv) {
    SWlState state;

    for (int i = 1; i < argc; i++) {
        const std::string ARG = argv[i];

        if (ARG == "--debug")
            debug = true;
        else if (ARG == "--min" && i + 2 < argc) {
            state.minSize = {std::stoi(argv[i + 1]), std::stoi(argv[i + 2])};
            i += 2;
        } else if (ARG == "--hint" && i + 4 < argc) {
            // Separate min and max, e.g. to advertise only one axis as fixed (which is enough for
            // Hyprland to auto-float the window) without declaring the whole output as the minimum.
            state.minSize = {std::stoi(argv[i + 1]), std::stoi(argv[i + 2])};
            state.maxSize = {std::stoi(argv[i + 3]), std::stoi(argv[i + 4])};
            i += 4;
        } else if (ARG == "--size" && i + 2 < argc) {
            state.forceSize = {std::stoi(argv[i + 1]), std::stoi(argv[i + 2])};
            i += 2;
        } else if (ARG == "--initial-fs")
            state.initialFS = true;
        else if (ARG == "--parent")
            state.wantsParent = true;
    }

    state.display = wl_display_connect(nullptr);
    if (!state.display) {
        clientLog("Failed to connect to wayland display");
        return -1;
    }

    if (!bindRegistry(state) || !setupToplevel(state))
        return -1;

    std::array<char, 1024> readBuf;
    readBuf.fill(0);

    wl_display_flush(state.display);

    struct pollfd fds[2] = {{.fd = wl_display_get_fd(state.display), .events = POLLIN | POLLOUT}, {.fd = STDIN_FILENO, .events = POLLIN}};
    while (!shouldExit && poll(fds, 2, 0) != -1) {
        if (fds[0].revents & POLLIN) {
            wl_display_flush(state.display);

            if (wl_display_prepare_read(state.display) == 0) {
                wl_display_read_events(state.display);
                wl_display_dispatch_pending(state.display);
            } else
                wl_display_dispatch(state.display);

            int ret = 0;
            do {
                ret = wl_display_dispatch_pending(state.display);
                wl_display_flush(state.display);
            } while (ret > 0);
        }

        if (fds[1].revents & POLLIN) {
            const ssize_t BYTES = read(fds[1].fd, readBuf.data(), readBuf.size() - 1);
            if (BYTES <= 0)
                continue;

            readBuf[BYTES] = 0;
            parseRequest(state, std::string{readBuf.data()});
        }
    }

    wl_display* display = state.display;
    state               = {};

    wl_display_disconnect(display);
    return 0;
}
