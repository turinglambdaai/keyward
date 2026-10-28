#include "pch.h"
#include "MainWindow.xaml.h"
#if __has_include("MainWindow.g.cpp")
#include "MainWindow.g.cpp"
#endif
#include "GeneratedBackend.hpp"

#include <shobjidl_core.h>

#include <algorithm>
#include <cstring>
#include <cwctype>
#include <stdexcept>

namespace winrt::RivetHost::implementation {

namespace mx = winrt::Microsoft::UI::Xaml;
namespace mxc = winrt::Microsoft::UI::Xaml::Controls;
namespace mxt = winrt::Microsoft::UI::Text;

namespace {

std::filesystem::path executable_path() {
  std::wstring buffer(32768, L'\0');
  auto const length = ::GetModuleFileNameW(nullptr, buffer.data(),
                                          static_cast<DWORD>(buffer.size()));
  if (length == 0 || length == buffer.size()) {
    throw std::runtime_error("GetModuleFileNameW failed");
  }
  buffer.resize(length);
  return std::filesystem::path(buffer);
}

std::string utf8_from_wide(std::wstring const& wide) {
  if (wide.empty()) {
    return {};
  }
  auto const size = ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                          wide.data(),
                                          static_cast<int>(wide.size()),
                                          nullptr, 0, nullptr, nullptr);
  if (size <= 0) {
    throw std::runtime_error("WideCharToMultiByte failed");
  }
  std::string result(static_cast<std::size_t>(size), '\0');
  if (::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(),
                            static_cast<int>(wide.size()), result.data(),
                            size, nullptr, nullptr) != size) {
    throw std::runtime_error("WideCharToMultiByte failed");
  }
  return result;
}

std::wstring wide(std::string const& text) {
  if (text.empty()) {
    return {};
  }
  auto const size = ::MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                          static_cast<int>(text.size()),
                                          nullptr, 0);
  if (size <= 0) {
    return {};
  }
  std::wstring result(static_cast<std::size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, text.data(),
                        static_cast<int>(text.size()), result.data(), size);
  return result;
}

std::string utf8(std::filesystem::path const& path) {
  return utf8_from_wide(path.wstring());
}

// The FontWeights statics live in Microsoft::UI::Text (payback precedent);
// auto keeps the returned FontWeight type whatever the SDK projects.
auto FontBold() { return mxt::FontWeights::Bold(); }
auto FontSemiBold() { return mxt::FontWeights::SemiBold(); }

rivet::windows::RacketRuntimeConfig runtime_config() {
  auto const exe = executable_path();
  auto const root = exe.parent_path();
  auto const runtime = root / L"runtime";

  rivet::windows::RacketRuntimeConfig config;
  config.executable_path = utf8(exe);
  config.petite_boot = utf8(runtime / L"petite.boot");
  config.scheme_boot = utf8(runtime / L"scheme.boot");
  config.racket_boot = utf8(runtime / L"racket.boot");
  config.backend_bundle = utf8(root / L"res" / L"core.zo");
  config.module_name = rivet_app::kModuleName;
  config.entry_symbol = rivet_app::kEntryName;
  config.dll_dir = runtime.wstring();
  return config;
}

// Status tones, matching the macOS host dot colors: ok is green, the quiet
// emptiness states are neutral gray, anything else needs attention.
mx::Media::SolidColorBrush ToneBrush(std::wstring const& status) {
  winrt::Windows::UI::Color color{};
  if (status == L"ok") {
    color = {255, 52, 199, 89};    // green
  } else if (status == L"no-key" || status == L"empty-section" ||
             status.rfind(L"empty", 0) == 0) {
    color = {255, 142, 142, 147};  // neutral gray
  } else {
    color = {255, 255, 149, 0};    // warn amber
  }
  mx::Media::SolidColorBrush brush(color);
  return brush;
}

bool ToneIsWarn(std::wstring const& status) {
  return status != L"ok" && status != L"no-key" &&
         status != L"empty-section" && status.rfind(L"empty", 0) != 0;
}

// Theme-neutral quiet fill: a translucent gray that reads as a card/chip on
// both light and dark backgrounds without hand-rolling theme lookup.
mx::Media::SolidColorBrush OverlayBrush() {
  return mx::Media::SolidColorBrush({26, 128, 128, 128});
}

mx::Media::SolidColorBrush DimBrush() {
  return mx::Media::SolidColorBrush({255, 128, 128, 128});
}

// Purpose hints for the family's known entry names (issue #2): every name
// is load-bearing, so the app itself answers "what consumes this?" before
// anyone guesses at deleting it. Unknown names get an explicit confirm
// line instead of silence.
std::wstring EntryPurposeHint(std::string const& name) {
  if (name == "UPDATE_ED25519_PRIVATE_KEY_B64") {
    return L"Consumed by the release workflow (CI manifest signing)";
  }
  if (name == "UPDATE_ED25519_PUBLIC_KEY_SPKI_B64") {
    return L"Pasted into the Racket-side updater (SPKI form)";
  }
  if (name == "UPDATE_ED25519_PUBLIC_KEY_RAW_TAIL32_B64") {
    return L"Pasted into the macOS Swift host UpdateService (raw 32-byte form)";
  }
  if (name == "RIVET_UPDATE_KEY_ID") {
    return L"Written into the signed update manifest";
  }
  auto const starts_with = [&name](char const* prefix) {
    return name.rfind(prefix, 0) == 0;
  };
  auto const ends_with = [&name](char const* suffix) {
    auto const len = std::strlen(suffix);
    return name.size() >= len &&
           name.compare(name.size() - len, len, suffix) == 0;
  };
  if (ends_with("_FPR")) {
    return L"Pairing anchor for Deep Check";
  }
  if (starts_with("LICENSE_") || starts_with("PERMIT_")) {
    return L"Commercial signing — different lifecycle from update keys";
  }
  return L"No known consumer — confirm what reads it before deleting";
}

}  // namespace

MainWindow::MainWindow() {
  InitializeComponent();
  Title(L"Keyward");
  // Ordinary window close and OS session end (logoff/shutdown) both funnel
  // into the same orderly backend stop. The console-control callback runs
  // on its own thread, so it only touches the thread-safe stop() — never
  // XAML state.
  Closed([this](auto const&, auto const&) { StopBackendOrderly(); });
  try {
    rivet::system::InstallShutdownHook([this] { StopBackendOrderly(); });
  } catch (std::exception const&) {
    // Signal coverage is platform policy and never blocks startup; the
    // window-close path above still runs the orderly shutdown.
  }
  InitializeBackendAsync();
}

void MainWindow::StopBackendOrderly() {
  if (auto backend = std::atomic_load(&backend_); backend != nullptr) {
    backend->stop();
  }
}

winrt::fire_and_forget MainWindow::InitializeBackendAsync() {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = std::make_shared<rivet::windows::Backend>(runtime_config());

  try {
    // Booting the embedded runtime can block on file I/O, so only startup is
    // moved off the UI thread. RPC traffic below is completion-driven.
    co_await winrt::resume_background();
    backend->start();

    dispatcher.TryEnqueue([weak, backend = std::move(backend)]() mutable {
      if (auto window = weak.get()) {
        window->backend_ = std::move(backend);
        window->BootstrapStore();
      } else {
        // Never destroy the last Backend reference on its own reader thread.
        std::thread([backend = std::move(backend)]() mutable {
          backend->stop();
        }).detach();
      }
    });
  } catch (std::exception const& e) {
    auto message = std::string(e.what());
    dispatcher.TryEnqueue([weak, message = std::move(message)] {
      if (auto window = weak.get()) {
        window->SetErrorUi(message);
      }
    });
  }
}

void MainWindow::SetReadyUi() {
  ready_ = true;
  // Readiness is a fact about the engine, not about whether a vault is
  // armed: the no-vault state still reports success (macOS/Linux parity),
  // only the menu items wait for a store.
  StatusBar().Severity(mx::Controls::InfoBarSeverity::Success);
  StatusBar().Message(L"Embedded Racket CS is ready");
  auto const armed = !store_path_.empty();
  DeepCheckItem().IsEnabled(armed);
  SnapshotsItem().IsEnabled(armed);
}

void MainWindow::SetErrorUi(std::string const& message) {
  StatusBar().Severity(mxc::InfoBarSeverity::Error);
  StatusBar().Message(winrt::to_hstring(message));
}

void MainWindow::SetStatusMessage(std::wstring const& message) {
  StatusMessage().Text(winrt::hstring(message));
}

// ---------------------------------------------------------------------------
// RPC flows
// ---------------------------------------------------------------------------

void MainWindow::BootstrapStore() {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = backend_;
  if (!backend || !backend->running()) {
    SetErrorUi("Racket backend is not running");
    return;
  }
  try {
    rivet_app::API api(*backend);
    (void)api.store_path_async(
        [dispatcher, weak](rivet_app::Result<std::string> result) {
          try {
            auto const path = result.get();
            dispatcher.TryEnqueue([weak, path] {
              if (auto window = weak.get()) {
                window->store_path_ = wide(path);
                window->StorePathText().Text(
                    winrt::hstring(window->store_path_));
                window->SetReadyUi();
                window->RenderSidebar();
                window->RenderDetail();
                window->RefreshProducts([weak] {
                  if (auto window = weak.get()) {
                    window->SetStatusMessage(
                        L"Connected — " +
                        std::to_wstring(window->products_.size()) +
                        L" products");
                  }
                });
              }
            });
          } catch (std::exception const& e) {
            auto message = std::string(e.what());
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) {
                window->SetErrorUi(message);
              }
            });
          }
        });
  } catch (std::exception const& e) {
    SetErrorUi(e.what());
  }
}

void MainWindow::RefreshProducts(std::function<void()> then) {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = backend_;
  if (!backend || !backend->running()) {
    return;
  }
  try {
    rivet_app::API api(*backend);
    (void)api.store_info_async(
        [dispatcher, weak, then = std::move(then)](
            rivet_app::Result<std::vector<std::vector<std::string>>> result) {
          try {
            auto const rows = result.get();
            dispatcher.TryEnqueue([weak, rows, then = std::move(then)] {
              if (auto window = weak.get()) {
                window->products_.clear();
                for (auto const& row : rows) {
                  ProductInfo info;
                  if (!row.empty()) info.name = wide(row[0]);
                  if (row.size() > 1) info.entries = wide(row[1]);
                  if (row.size() > 2) info.key_id = wide(row[2]);
                  if (row.size() > 3) info.fingerprint = wide(row[3]);
                  if (row.size() > 4) info.status = wide(row[4]);
                  window->products_.push_back(std::move(info));
                }
                if (!window->selected_.empty()) {
                  auto const wanted = window->selected_;
                  auto hit = std::find_if(
                      window->products_.begin(), window->products_.end(),
                      [&wanted](ProductInfo const& p) {
                        return p.name == wanted;
                      });
                  if (hit == window->products_.end()) {
                    window->selected_.clear();
                    window->entries_.clear();
                  }
                }
                window->RenderSidebar();
                window->RenderDetail();
                // Snapshots are not part of store_info; refresh the list
                // so the sidebar tile shows the live count.
                window->LoadSnapshots();
                if (then) {
                  then();
                }
              }
            });
          } catch (std::exception const& e) {
            auto message = std::string(e.what());
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) {
                window->SetErrorUi(message);
              }
            });
          }
        });
  } catch (std::exception const& e) {
    SetErrorUi(e.what());
  }
}

void MainWindow::CheckAll() {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = backend_;
  if (!backend || !backend->running() || !ready_ || store_path_.empty()) {
    return;
  }
  try {
    rivet_app::API api(*backend);
    (void)api.check_store_async(
        [dispatcher, weak](
            rivet_app::Result<std::vector<std::vector<std::string>>> result) {
          try {
            auto const rows = result.get();
            dispatcher.TryEnqueue([weak, rows] {
              if (auto window = weak.get()) {
                window->checks_.clear();
                for (auto const& row : rows) {
                  // The "(file)" row is the whole-file report; per-product
                  // check chips come from the remaining sections.
                  if (row.empty() || row[0] == "(file)") {
                    continue;
                  }
                  CheckRow check;
                  check.name = wide(row[0]);
                  if (row.size() > 4) check.kind = wide(row[4]);
                  if (row.size() > 5) check.fingerprint = wide(row[5]);
                  if (row.size() > 6) check.paired = wide(row[6]);
                  if (row.size() > 7) check.status = wide(row[7]);
                  window->checks_.push_back(std::move(check));
                }
                window->RenderDetail();
                // Product statuses move after a check (macOS parity):
                // refresh the sidebar dots and captions from store-info.
                window->RefreshProducts(nullptr);
                window->SetStatusMessage(
                    L"Deep check finished — " +
                    std::to_wstring(window->checks_.size()) + L" sections");
              }
            });
          } catch (std::exception const& e) {
            auto message = std::string(e.what());
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) {
                window->ShowEngineMessage(message);
              }
            });
          }
        });
  } catch (std::exception const& e) {
    ShowEngineMessage(e.what());
  }
}

void MainWindow::SelectProduct(std::wstring const& name) {
  selected_ = name;
  ++selection_generation_;
  auto const generation = selection_generation_;
  entries_.clear();
  RenderSidebar();
  RenderDetail();

  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = backend_;
  if (!backend || !backend->running()) {
    return;
  }
  try {
    rivet_app::API api(*backend);
    (void)api.entry_list_async(
        utf8_from_wide(name),
        [dispatcher, weak, generation](
            rivet_app::Result<std::vector<std::vector<std::string>>> result) {
          try {
            auto const rows = result.get();
            dispatcher.TryEnqueue([weak, rows, generation] {
              if (auto window = weak.get()) {
                // A stale entry list never overwrites the newer selection.
                if (generation != window->selection_generation_) {
                  return;
                }
                window->entries_.clear();
                for (auto const& row : rows) {
                  EntryRow entry;
                  if (!row.empty()) entry.name = row[0];
                  if (row.size() > 1) entry.state = row[1];
                  window->entries_.push_back(std::move(entry));
                }
                window->RenderDetail();
              }
            });
          } catch (std::exception const& e) {
            auto message = std::string(e.what());
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) {
                window->ShowEngineMessage(message);
              }
            });
          }
        });
  } catch (std::exception const& e) {
    ShowEngineMessage(e.what());
  }
}

void MainWindow::CopyEntry(EntryRow const& entry) {
  if (selected_.empty()) {
    return;
  }
  auto const product = selected_;
  auto const generation = selection_generation_;
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = backend_;
  if (!backend || !backend->running()) {
    return;
  }
  try {
    rivet_app::API api(*backend);
    (void)api.entry_get_async(
        utf8_from_wide(product), entry.name,
        [dispatcher, weak, name = entry.name, product, generation](
            rivet_app::Result<std::string> result) {
          try {
            auto const value = result.get();
            dispatcher.TryEnqueue([weak, name, value, product, generation] {
              if (auto window = weak.get()) {
                // The copy is bound to the product whose rows are on
                // screen; a selection change since the click drops it
                // instead of landing a secret against a different header.
                if (window->selected_ != product ||
                    generation != window->selection_generation_) {
                  window->SetStatusMessage(
                      L"Copy skipped — selection changed");
                  return;
                }
                // The value's only way out: clipboard, never the screen.
                // The Title marks the copy as ours (the marker is not the
                // secret) so the expiry tick can recognize it.
                try {
                  winrt::Windows::ApplicationModel::DataTransfer::DataPackage
                      package;
                  package.SetText(winrt::to_hstring(value));
                  package.Properties().Title(L"Keyward copied secret");
                  winrt::Windows::ApplicationModel::DataTransfer::Clipboard::
                      SetContent(package);
                } catch (...) {
                  // A clipboard briefly locked by another process must not
                  // crash the app; report and keep the value off-screen.
                  window->SetStatusMessage(L"Copy failed — the clipboard "
                                           L"rejected the content");
                  return;
                }
                window->ScheduleClipboardExpiry();
                window->SetStatusMessage(
                    L"Copied " + wide(name) +
                    L" — raw value on the clipboard, other apps can read "
                    L"it; auto-clears in 30 s unless something else "
                    L"copies first");
              }
            });
          } catch (std::exception const& e) {
            auto message = std::string(e.what());
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) {
                window->ShowEngineMessage(message);
              }
            });
          }
        });
  } catch (std::exception const& e) {
    ShowEngineMessage(e.what());
  }
}

// Optional expiry: erase the copied value 30 s later, but only while the
// clipboard still holds what this action put there — recognized through
// the marker Title, never by reading the value back. A user copy in
// between replaces the content and survives untouched. OS clipboard
// history/sync is out of our control and never claimed otherwise.
void MainWindow::ScheduleClipboardExpiry() {
  using winrt::Windows::ApplicationModel::DataTransfer::Clipboard;
  if (clipboard_expiry_timer_ == nullptr) {
    auto timer = DispatcherQueue().CreateTimer();
    timer.IsRepeating(false);
    timer.Tick([weak = get_weak()](auto const&, auto const&) {
      if (auto window = weak.get()) {
        try {
          auto const view = Clipboard::GetContent();
          if (view.Properties().Title() == L"Keyward copied secret") {
            Clipboard::Clear();
            window->SetStatusMessage(
                L"Auto-cleared the copied key from the clipboard");
          }
        } catch (...) {
          // A clipboard briefly locked by another process (winrt error or
          // std exception) must never crash the expiry path; the value
          // simply stays this round.
        }
      }
    });
    clipboard_expiry_timer_ = std::move(timer);
  }
  clipboard_expiry_timer_.Stop();
  clipboard_expiry_timer_.Interval(std::chrono::seconds{30});
  clipboard_expiry_timer_.Start();
}

void MainWindow::SetEntry(std::wstring const& name, std::wstring const& value) {
  if (selected_.empty()) {
    return;
  }
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = backend_;
  if (!backend || !backend->running()) {
    return;
  }
  try {
    rivet_app::API api(*backend);
    auto const name_utf8 = utf8_from_wide(name);
    (void)api.entry_set_async(
        utf8_from_wide(selected_), name_utf8, utf8_from_wide(value),
        [dispatcher, weak, name = name_utf8](
            rivet_app::Result<std::string> result) {
          try {
            auto const summary = result.get();
            dispatcher.TryEnqueue([weak, name, summary] {
              if (auto window = weak.get()) {
                window->SetStatusMessage(L"Set " + wide(name) + L" — " +
                                         wide(summary));
                // Counts and chips live in store-info: refresh products,
                // then re-fetch the selection's rows, so the sidebar never
                // shows stale numbers (macOS/Linux parity).
                // RefreshProducts also refreshes the Snapshots tile.
                window->RefreshProducts([weak]() -> void {
                  if (auto current = weak.get()) {
                    if (!current->selected_.empty()) {
                      current->SelectProduct(current->selected_);
                    }
                  }
                });
              }
            });
          } catch (std::exception const& e) {
            auto message = std::string(e.what());
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) {
                window->ShowEngineMessage(message);
              }
            });
          }
        });
  } catch (std::exception const& e) {
    ShowEngineMessage(e.what());
  }
}

void MainWindow::DeleteEntry(std::string const& name) {
  if (selected_.empty()) {
    return;
  }
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = backend_;
  if (!backend || !backend->running()) {
    return;
  }
  try {
    rivet_app::API api(*backend);
    (void)api.entry_delete_async(
        utf8_from_wide(selected_), name,
        [dispatcher, weak, name](rivet_app::Result<bool> result) {
          try {
            result.get();
            dispatcher.TryEnqueue([weak, name] {
              if (auto window = weak.get()) {
                window->SetStatusMessage(L"Deleted " + wide(name) +
                                         L" (snapshot taken)");
                window->RefreshProducts([weak]() -> void {
                  if (auto current = weak.get()) {
                    if (!current->selected_.empty()) {
                      current->SelectProduct(current->selected_);
                    }
                  }
                });
              }
            });
          } catch (std::exception const& e) {
            auto message = std::string(e.what());
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) {
                window->ShowEngineMessage(message);
              }
            });
          }
        });
  } catch (std::exception const& e) {
    ShowEngineMessage(e.what());
  }
}

void MainWindow::ImportKey(std::string const& name,
                           std::filesystem::path const& file_path) {
  if (selected_.empty()) {
    return;
  }
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = backend_;
  if (!backend || !backend->running()) {
    return;
  }
  try {
    rivet_app::API api(*backend);
    (void)api.entry_import_file_async(
        utf8_from_wide(selected_), name, utf8(file_path),
        [dispatcher, weak, name](rivet_app::Result<std::string> result) {
          try {
            auto const summary = result.get();
            dispatcher.TryEnqueue([weak, name, summary] {
              if (auto window = weak.get()) {
                window->SetStatusMessage(L"Imported " + wide(name) + L" — " +
                                         wide(summary));
                window->RefreshProducts([weak]() -> void {
                  if (auto current = weak.get()) {
                    if (!current->selected_.empty()) {
                      current->SelectProduct(current->selected_);
                    }
                  }
                });
              }
            });
          } catch (std::exception const& e) {
            auto message = std::string(e.what());
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) {
                window->ShowEngineMessage(message);
              }
            });
          }
        });
  } catch (std::exception const& e) {
    ShowEngineMessage(e.what());
  }
}

void MainWindow::GenerateUpdateKey() {
  if (selected_.empty()) {
    return;
  }
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = backend_;
  if (!backend || !backend->running()) {
    return;
  }
  try {
    rivet_app::API api(*backend);
    (void)api.keypair_generate_async(
        utf8_from_wide(selected_),
        [dispatcher, weak](
            rivet_app::Result<std::vector<std::string>> result) {
          try {
            auto const row = result.get();
            dispatcher.TryEnqueue([weak, row] {
              if (auto window = weak.get()) {
                auto const key_id = row.empty() ? L"" : wide(row[0]);
                auto const fingerprint = row.size() > 1 ? wide(row[1]) : L"";
                window->SetStatusMessage(L"Generated " + key_id +
                                         L" — fingerprint " + fingerprint +
                                         L" (collected into the vault)");
                window->RefreshProducts([weak]() -> void {
                  if (auto current = weak.get()) {
                    if (!current->selected_.empty()) {
                      current->SelectProduct(current->selected_);
                    }
                  }
                });
              }
            });
          } catch (std::exception const& e) {
            auto message = std::string(e.what());
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) {
                window->ShowEngineMessage(message);
              }
            });
          }
        });
  } catch (std::exception const& e) {
    ShowEngineMessage(e.what());
  }
}

void MainWindow::LoadSnapshots() {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = backend_;
  if (!backend || !backend->running()) {
    return;
  }
  try {
    rivet_app::API api(*backend);
    (void)api.snapshot_list_async(
        [dispatcher, weak](
            rivet_app::Result<std::vector<std::vector<std::string>>> result) {
          try {
            auto const rows = result.get();
            dispatcher.TryEnqueue([weak, rows] {
              if (auto window = weak.get()) {
                window->snapshots_.clear();
                for (auto const& row : rows) {
                  SnapshotRow snap;
                  if (!row.empty()) snap.stamp = row[0];
                  if (row.size() > 1) snap.size = row[1];
                  window->snapshots_.push_back(std::move(snap));
                }
                // The open snapshots dialog re-renders its rows when the
                // list lands (first load included); the sidebar tile
                // re-renders with the fresh count.
                if (window->snapshot_refresher_ != nullptr) {
                  (*window->snapshot_refresher_)();
                }
                window->RenderSidebar();
              }
            });
          } catch (std::exception const& e) {
            auto message = std::string(e.what());
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) {
                window->ShowEngineMessage(message);
              }
            });
          }
        });
  } catch (std::exception const& e) {
    ShowEngineMessage(e.what());
  }
}

void MainWindow::RestoreSnapshot(SnapshotRow const& snap) {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = backend_;
  if (!backend || !backend->running()) {
    return;
  }
  try {
    rivet_app::API api(*backend);
    (void)api.snapshot_restore_async(
        snap.stamp,
        [dispatcher, weak, stamp = snap.stamp](rivet_app::Result<bool> result) {
          try {
            result.get();
            dispatcher.TryEnqueue([weak, stamp] {
              if (auto window = weak.get()) {
                window->SetStatusMessage(L"Restored " + wide(stamp) +
                                         L" (pre-restore snapshot taken)");
                // The restored file may hold different entries for the
                // product still on screen — refresh products, then re-fetch
                // the selection's rows (macOS parity).
                window->RefreshProducts([weak]() -> void {
                  if (auto current = weak.get()) {
                    if (!current->selected_.empty()) {
                      current->SelectProduct(current->selected_);
                    }
                  }
                });
              }
            });
          } catch (std::exception const& e) {
            auto message = std::string(e.what());
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) {
                window->ShowEngineMessage(message);
              }
            });
          }
        });
  } catch (std::exception const& e) {
    ShowEngineMessage(e.what());
  }
}

void MainWindow::OpenStoreAsync(std::wstring const& path) {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = backend_;
  if (!backend || !backend->running()) {
    return;
  }
  try {
    rivet_app::API api(*backend);
    (void)api.store_open_async(
        utf8_from_wide(path),
        [dispatcher, weak](rivet_app::Result<std::string> result) {
          try {
            auto const opened = result.get();
            dispatcher.TryEnqueue([weak, opened] {
              if (auto window = weak.get()) {
                window->store_path_ = wide(opened);
                window->StorePathText().Text(
                    winrt::hstring(window->store_path_));
                window->products_.clear();
                window->selected_.clear();
                // Invalidate entry/copy completions still in flight for
                // the previous store's selection.
                ++window->selection_generation_;
                window->checks_.clear();
                window->entries_.clear();
                window->snapshots_.clear();
                window->RenderSidebar();
                window->RenderDetail();
                window->RefreshProducts(nullptr);
                window->SetStatusMessage(L"Store switched: " + wide(opened));
              }
            });
          } catch (std::exception const& e) {
            auto message = std::string(e.what());
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) {
                window->ShowEngineMessage(message);
              }
            });
          }
        });
  } catch (std::exception const& e) {
    ShowEngineMessage(e.what());
  }
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

namespace {

// One quiet summary tile: label left, quiet count right, translucent fill.
mx::UIElement MakeTile(std::wstring const& title, std::wstring const& count) {
  mxc::Border card;
  card.CornerRadius({6, 6, 6, 6});
  card.Background(OverlayBrush());
  card.Padding({8, 6, 8, 6});
  mxc::Grid row;
  row.ColumnSpacing(4);
  row.ColumnDefinitions().Append(mxc::ColumnDefinition{});
  row.ColumnDefinitions().Append(mxc::ColumnDefinition{});
  row.ColumnDefinitions().GetAt(0).Width(
      mx::GridLength{1, mx::GridUnitType::Star});
  row.ColumnDefinitions().GetAt(1).Width(
      mx::GridLength{0, mx::GridUnitType::Auto});
  mxc::TextBlock label;
  label.Text(winrt::hstring(title));
  label.FontSize(12);
  label.VerticalAlignment(mx::VerticalAlignment::Center);
  mxc::TextBlock value;
  value.Text(winrt::hstring(count));
  value.FontSize(12);
  value.Foreground(DimBrush());
  value.VerticalAlignment(mx::VerticalAlignment::Center);
  mxc::Grid::SetColumn(label, 0);
  mxc::Grid::SetColumn(value, 1);
  row.Children().Append(label);
  row.Children().Append(value);
  card.Child(row);
  return card;
}

// A quiet label/value chip: small label + value, translucent fill. With an
// empty label it degenerates to the status chip (dot rendered by the caller
// is folded into the value text color).
mx::UIElement MakeChip(std::wstring const& label, std::wstring const& value,
                       bool mono, bool ok, bool warn) {
  mxc::Border chip;
  chip.CornerRadius({6, 6, 6, 6});
  chip.Background(OverlayBrush());
  chip.Padding({10, 5, 10, 5});
  chip.VerticalAlignment(mx::VerticalAlignment::Center);
  mxc::StackPanel row;
  row.Orientation(mx::Controls::Orientation::Horizontal);
  row.Spacing(5);
  mxc::TextBlock key;
  key.Text(winrt::hstring(label));
  key.FontSize(10);
  key.FontWeight(FontSemiBold());
  key.Foreground(DimBrush());
  key.VerticalAlignment(mx::VerticalAlignment::Center);
  mxc::TextBlock content;
  content.Text(winrt::hstring(value.empty() ? L"—" : value));
  content.FontSize(12);
  if (mono) {
    content.FontFamily(mx::Media::FontFamily(L"Consolas"));
  }
  if (ok) {
    content.Foreground(ToneBrush(L"ok"));
  } else if (warn) {
    content.Foreground(ToneBrush(L"warn"));
  }
  content.VerticalAlignment(mx::VerticalAlignment::Center);
  content.MaxLines(1);
  content.TextTrimming(mx::TextTrimming::CharacterEllipsis);
  row.Children().Append(key);
  row.Children().Append(content);
  chip.Child(row);
  return chip;
}

}  // namespace

void MainWindow::RenderSidebar() {
  auto const tiles = SummaryGrid().Children();
  tiles.Clear();
  auto const ok_count = static_cast<std::int32_t>(std::count_if(
      products_.begin(), products_.end(),
      [](ProductInfo const& p) { return p.status == L"ok"; }));
  tiles.Append(MakeTile(L"Products", std::to_wstring(products_.size())));
  tiles.Append(MakeTile(L"Paired", std::to_wstring(ok_count)));
  tiles.Append(MakeTile(
      L"Attention",
      std::to_wstring(std::count_if(products_.begin(), products_.end(),
                                    [](ProductInfo const& p) {
                                      return ToneIsWarn(p.status);
                                    }))));
  tiles.Append(MakeTile(L"Snapshots",
                        std::to_wstring(snapshots_.size())));
  for (std::uint32_t i = 0; i < tiles.Size(); ++i) {
    auto tile = tiles.GetAt(i);
    mxc::Grid::SetColumn(tile.as<mxc::Border>(), i % 2);
    mxc::Grid::SetRow(tile.as<mxc::Border>(), i / 2);
  }

  auto const items = ProductList().Children();
  items.Clear();
  for (auto const& product : products_) {
    mxc::Button row;
    row.HorizontalAlignment(mx::HorizontalAlignment::Stretch);
    row.HorizontalContentAlignment(mx::HorizontalAlignment::Stretch);
    row.Padding({8, 6, 8, 6});
    row.CornerRadius({6, 6, 6, 6});
    row.Background(mx::Media::SolidColorBrush({0, 0, 0, 0}));
    row.BorderThickness({0, 0, 0, 0});

    mxc::Grid grid;
    grid.ColumnSpacing(8);
    grid.ColumnDefinitions().Append(mxc::ColumnDefinition{});
    grid.ColumnDefinitions().Append(mxc::ColumnDefinition{});
    grid.ColumnDefinitions().Append(mxc::ColumnDefinition{});
    grid.ColumnDefinitions().GetAt(0).Width(
        mx::GridLength{0, mx::GridUnitType::Auto});
    grid.ColumnDefinitions().GetAt(1).Width(
        mx::GridLength{1, mx::GridUnitType::Star});
    grid.ColumnDefinitions().GetAt(2).Width(
        mx::GridLength{0, mx::GridUnitType::Auto});

    mx::Shapes::Ellipse dot;
    dot.Width(8);
    dot.Height(8);
    dot.Fill(ToneBrush(product.status));
    dot.VerticalAlignment(mx::VerticalAlignment::Center);

    mxc::StackPanel names;
    names.Spacing(1);
    mxc::TextBlock name;
    name.Text(winrt::hstring(product.name));
    name.FontSize(13);
    name.TextTrimming(mx::TextTrimming::CharacterEllipsis);
    mxc::TextBlock caption;
    caption.Text(winrt::hstring(product.status == L"ok" ? product.fingerprint
                                                        : product.status));
    caption.FontSize(10);
    caption.FontFamily(mx::Media::FontFamily(L"Consolas"));
    caption.Foreground(DimBrush());
    caption.TextTrimming(mx::TextTrimming::CharacterEllipsis);
    names.Children().Append(name);
    names.Children().Append(caption);

    mxc::TextBlock count;
    count.Text(winrt::hstring(product.entries));
    count.FontSize(11);
    count.Foreground(DimBrush());
    count.VerticalAlignment(mx::VerticalAlignment::Center);

    mxc::Grid::SetColumn(dot, 0);
    mxc::Grid::SetColumn(names, 1);
    mxc::Grid::SetColumn(count, 2);
    grid.Children().Append(dot);
    grid.Children().Append(names);
    grid.Children().Append(count);
    row.Content(grid);

    auto const weak = get_weak();
    auto const product_name = product.name;
    row.Click([weak, product_name](auto const&, auto const&) {
      if (auto window = weak.get()) {
        window->SelectProduct(product_name);
      }
    });
    items.Append(row);
  }
}

void MainWindow::RenderDetail() {
  auto const show_no_vault = store_path_.empty();
  auto const show_intro = !show_no_vault && selected_.empty();

  NoVaultPane().Visibility(show_no_vault ? mx::Visibility::Visible
                                         : mx::Visibility::Collapsed);
  IntroPane().Visibility(show_intro ? mx::Visibility::Visible
                                    : mx::Visibility::Collapsed);
  ProductPane().Visibility((show_no_vault || show_intro)
                               ? mx::Visibility::Collapsed
                               : mx::Visibility::Visible);
  if (show_no_vault || show_intro) {
    return;
  }

  auto const children = ProductDetail().Children();
  children.Clear();

  auto const product_it =
      std::find_if(products_.begin(), products_.end(),
                   [this](ProductInfo const& p) {
                     return p.name == selected_;
                   });
  if (product_it == products_.end()) {
    return;
  }
  auto const& product = *product_it;

  // ---- header card ----
  mxc::Border header;
  header.CornerRadius({14, 14, 14, 14});
  header.Padding({18, 18, 18, 18});
  header.Background(OverlayBrush());
  mxc::StackPanel header_stack;
  header_stack.Spacing(10);

  mxc::Grid title_row;
  title_row.ColumnSpacing(8);
  title_row.ColumnDefinitions().Append(mxc::ColumnDefinition{});
  title_row.ColumnDefinitions().Append(mxc::ColumnDefinition{});
  title_row.ColumnDefinitions().GetAt(0).Width(
      mx::GridLength{1, mx::GridUnitType::Star});
  title_row.ColumnDefinitions().GetAt(1).Width(
      mx::GridLength{0, mx::GridUnitType::Auto});

  mxc::TextBlock title;
  title.Text(winrt::hstring(product.name));
  title.FontSize(22);
  title.FontWeight(FontBold());
  title.TextWrapping(mx::TextWrapping::Wrap);
  title.VerticalAlignment(mx::VerticalAlignment::Center);
  mxc::Grid::SetColumn(title, 0);
  title_row.Children().Append(title);

  // Header actions (macOS parity): Deep Check and Snapshots sit beside the
  // product title, not only in the menu bar.
  auto const header_weak = get_weak();
  mxc::StackPanel header_actions;
  header_actions.Orientation(mx::Controls::Orientation::Horizontal);
  header_actions.Spacing(8);
  header_actions.VerticalAlignment(mx::VerticalAlignment::Center);
  mxc::Button header_check;
  header_check.Content(winrt::box_value(L"Deep Check"));
  header_check.FontSize(12);
  header_check.Padding({10, 4, 10, 4});
  header_check.Click([header_weak](auto const&, auto const&) {
    if (auto window = header_weak.get()) {
      window->CheckAll();
    }
  });
  header_actions.Children().Append(header_check);
  mxc::Button header_snapshots;
  header_snapshots.Content(winrt::box_value(L"Snapshots"));
  header_snapshots.FontSize(12);
  header_snapshots.Padding({10, 4, 10, 4});
  header_snapshots.Click([header_weak](auto const&, auto const&) {
    if (auto window = header_weak.get()) {
      window->SnapshotsDialogAsync();
    }
  });
  header_actions.Children().Append(header_snapshots);
  mxc::Grid::SetColumn(header_actions, 1);
  title_row.Children().Append(header_actions);
  header_stack.Children().Append(title_row);

  mxc::StackPanel info_chips;
  info_chips.Orientation(mx::Controls::Orientation::Horizontal);
  info_chips.Spacing(8);
  info_chips.Children().Append(
      MakeChip(L"ENTRIES", product.entries, false, false, false));
  if (!product.key_id.empty()) {
    info_chips.Children().Append(
        MakeChip(L"KEY ID", product.key_id, true, false, false));
  }
  if (!product.fingerprint.empty() && product.fingerprint != L"-") {
    info_chips.Children().Append(
        MakeChip(L"FINGERPRINT", product.fingerprint, true, false, false));
  }
  info_chips.Children().Append(
      MakeChip(L"", product.status, false, product.status == L"ok",
               ToneIsWarn(product.status)));
  header_stack.Children().Append(info_chips);

  for (auto const& check : checks_) {
    if (check.name != product.name) {
      continue;
    }
    mxc::StackPanel check_chips;
    check_chips.Orientation(mx::Controls::Orientation::Horizontal);
    check_chips.Spacing(8);
    check_chips.Children().Append(
        MakeChip(L"KIND", check.kind, false, false, false));
    check_chips.Children().Append(MakeChip(
        L"PAIRED", check.paired, false, check.paired == L"yes",
        check.paired != L"yes"));
    check_chips.Children().Append(MakeChip(
        L"CHECK", check.status, false, check.status == L"ok",
        check.status != L"ok"));
    header_stack.Children().Append(check_chips);
  }
  header.Child(header_stack);
  children.Append(header);

  // ---- entries section ----
  mxc::Grid entries_header;
  entries_header.ColumnSpacing(8);
  entries_header.ColumnDefinitions().Append(mxc::ColumnDefinition{});
  entries_header.ColumnDefinitions().Append(mxc::ColumnDefinition{});
  entries_header.ColumnDefinitions().GetAt(0).Width(
      mx::GridLength{1, mx::GridUnitType::Star});
  entries_header.ColumnDefinitions().GetAt(1).Width(
      mx::GridLength{0, mx::GridUnitType::Auto});
  mxc::TextBlock entries_caption;
  entries_caption.Text(L"Entries");
  entries_caption.FontSize(13);
  entries_caption.FontWeight(FontSemiBold());
  entries_caption.Foreground(DimBrush());
  entries_caption.VerticalAlignment(mx::VerticalAlignment::Center);

  mxc::Button add_button;
  add_button.Content(winrt::box_value(L"Add ＋"));
  add_button.Padding({12, 4, 12, 4});
  auto add_flyout = mxc::MenuFlyout();
  auto const weak = get_weak();
  auto new_entry_item = mxc::MenuFlyoutItem();
  new_entry_item.Text(L"New entry…");
  new_entry_item.Click([weak](auto const&, auto const&) {
    if (auto window = weak.get()) {
      window->NewEntryDialogAsync();
    }
  });
  add_flyout.Items().Append(new_entry_item);
  auto import_item = mxc::MenuFlyoutItem();
  import_item.Text(L"Import PEM file…");
  import_item.Click([weak](auto const&, auto const&) {
    if (auto window = weak.get()) {
      window->ImportKeyPickAsync("UPDATE_ED25519_PRIVATE_KEY_B64");
    }
  });
  add_flyout.Items().Append(import_item);
  auto generate_item = mxc::MenuFlyoutItem();
  generate_item.Text(L"Generate update key…");
  generate_item.Click([weak](auto const&, auto const&) {
    if (auto window = weak.get()) {
      window->ConfirmGenerateKeyAsync();
    }
  });
  add_flyout.Items().Append(generate_item);
  add_button.Flyout(add_flyout);
  mxc::Grid::SetColumn(entries_caption, 0);
  mxc::Grid::SetColumn(add_button, 1);
  entries_header.Children().Append(entries_caption);
  entries_header.Children().Append(add_button);
  children.Append(entries_header);

  if (entries_.empty()) {
    mxc::TextBlock empty;
    empty.Text(L"No entries in this section.");
    empty.FontSize(13);
    empty.Foreground(DimBrush());
    empty.Padding({0, 10, 0, 10});
    children.Append(empty);
  }

  for (auto const& entry : entries_) {
    children.Append(MakeEntryCard(entry));
  }
}

mx::UIElement MainWindow::MakeEntryCard(EntryRow const& entry) {
  mxc::Border card;
  card.CornerRadius({6, 6, 6, 6});
  card.Padding({12, 9, 12, 9});
  card.Background(OverlayBrush());
  card.BorderBrush(mx::Media::SolidColorBrush({64, 128, 128, 128}));
  card.BorderThickness({1, 1, 1, 1});

  mxc::Grid grid;
  grid.ColumnSpacing(10);
  for (int i = 0; i < 4; ++i) {
    grid.ColumnDefinitions().Append(mxc::ColumnDefinition{});
  }
  grid.ColumnDefinitions().GetAt(0).Width(
      mx::GridLength{0, mx::GridUnitType::Auto});
  grid.ColumnDefinitions().GetAt(1).Width(
      mx::GridLength{1, mx::GridUnitType::Star});
  grid.ColumnDefinitions().GetAt(2).Width(
      mx::GridLength{0, mx::GridUnitType::Auto});
  grid.ColumnDefinitions().GetAt(3).Width(
      mx::GridLength{0, mx::GridUnitType::Auto});

  mxc::TextBlock lock;
  lock.Text(winrt::hstring(entry.state == "set" ? L"🔒" : L"🔓"));
  lock.FontSize(12);
  lock.VerticalAlignment(mx::VerticalAlignment::Center);

  mxc::StackPanel names;
  names.Orientation(mx::Controls::Orientation::Vertical);
  names.Spacing(1);
  names.VerticalAlignment(mx::VerticalAlignment::Center);

  mxc::TextBlock name;
  name.Text(winrt::to_hstring(entry.name));
  name.FontSize(13);
  name.FontFamily(mx::Media::FontFamily(L"Consolas"));
  name.TextTrimming(mx::TextTrimming::CharacterEllipsis);
  names.Children().Append(name);

  mxc::TextBlock hint;
  hint.Text(EntryPurposeHint(entry.name));
  hint.FontSize(10);
  hint.Foreground(DimBrush());
  hint.TextTrimming(mx::TextTrimming::CharacterEllipsis);
  names.Children().Append(hint);

  mxc::StackPanel tail;
  tail.Orientation(mx::Controls::Orientation::Horizontal);
  tail.Spacing(6);
  tail.VerticalAlignment(mx::VerticalAlignment::Center);
  if (entry.state == "empty") {
    mxc::TextBlock empty_badge;
    empty_badge.Text(L"empty");
    empty_badge.FontSize(10);
    empty_badge.FontWeight(FontSemiBold());
    empty_badge.Foreground(ToneBrush(L"warn"));
    empty_badge.VerticalAlignment(mx::VerticalAlignment::Center);
    tail.Children().Append(empty_badge);
  }
  auto const weak = get_weak();
  auto copy_button = mxc::Button();
  copy_button.Content(winrt::box_value(L"Copy"));
  copy_button.FontSize(11);
  copy_button.Padding({8, 2, 8, 2});
  copy_button.Click([weak, entry](auto const&, auto const&) {
    if (auto window = weak.get()) {
      window->CopyEntry(entry);
    }
  });
  tail.Children().Append(copy_button);

  mxc::Button more_button;
  more_button.Content(winrt::box_value(L"⋯"));
  more_button.FontSize(13);
  more_button.Padding({6, 2, 6, 2});
  auto row_menu = mxc::MenuFlyout();
  auto menu_copy = mxc::MenuFlyoutItem();
  menu_copy.Text(L"Copy value to clipboard");
  menu_copy.Click([weak, entry](auto const&, auto const&) {
    if (auto window = weak.get()) {
      window->CopyEntry(entry);
    }
  });
  row_menu.Items().Append(menu_copy);
  auto menu_import = mxc::MenuFlyoutItem();
  menu_import.Text(L"Import PEM file…");
  menu_import.Click([weak, entry](auto const&, auto const&) {
    if (auto window = weak.get()) {
      window->ImportKeyPickAsync(entry.name);
    }
  });
  row_menu.Items().Append(menu_import);
  auto menu_delete = mxc::MenuFlyoutItem();
  menu_delete.Text(L"Delete…");
  menu_delete.Click([weak, entry](auto const&, auto const&) {
    if (auto window = weak.get()) {
      window->ConfirmDeleteAsync(entry.name);
    }
  });
  row_menu.Items().Append(menu_delete);
  more_button.Flyout(row_menu);

  mxc::Grid::SetColumn(lock, 0);
  mxc::Grid::SetColumn(names, 1);
  mxc::Grid::SetColumn(tail, 2);
  mxc::Grid::SetColumn(more_button, 3);
  grid.Children().Append(lock);
  grid.Children().Append(names);
  grid.Children().Append(tail);
  grid.Children().Append(more_button);
  card.Child(grid);
  return card;
}

// ---------------------------------------------------------------------------
// Dialogs and pickers
// ---------------------------------------------------------------------------

winrt::fire_and_forget MainWindow::NewEntryDialogAsync() {
  if (selected_.empty()) {
    co_return;
  }
  auto name_box = mxc::TextBox{};
  name_box.PlaceholderText(L"NAME");
  auto value_box = mxc::TextBox{};
  value_box.PlaceholderText(L"value (single line)");
  auto panel = mxc::StackPanel{};
  panel.Spacing(8);
  panel.Children().Append(name_box);
  panel.Children().Append(value_box);

  auto dialog = mxc::ContentDialog{};
  dialog.Title(winrt::box_value(L"New entry in " + selected_));
  dialog.Content(winrt::box_value(panel));
  dialog.PrimaryButtonText(L"Set");
  dialog.CloseButtonText(L"Cancel");
  dialog.DefaultButton(mxc::ContentDialogButton::Primary);
  // The engine rejects an empty name, so Set waits for one (macOS/Linux
  // parity). Projected XAML types have no get_weak: the handler reaches
  // the dialog through the window member (cleared on close), so nothing
  // captures the dialog strongly and no ref cycle forms.
  dialog.IsPrimaryButtonEnabled(false);
  pending_entry_dialog_ = dialog;
  name_box.TextChanged([weak = get_weak()](auto const& sender, auto const&) {
    if (auto window = weak.get()) {
      if (auto current = window->pending_entry_dialog_) {
        auto box = sender.as<mxc::TextBox>();
        current.IsPrimaryButtonEnabled(box != nullptr &&
                                       !box.Text().empty());
      }
    }
  });
  dialog.XamlRoot(Content().XamlRoot());
  auto const choice = co_await dialog.ShowAsync();
  pending_entry_dialog_ = nullptr;
  if (choice != mxc::ContentDialogResult::Primary) {
    co_return;
  }
  auto name = std::wstring(name_box.Text());
  std::transform(name.begin(), name.end(), name.begin(), towupper);
  if (name.empty()) {
    co_return;
  }
  SetEntry(name, std::wstring(value_box.Text()));
}

winrt::fire_and_forget MainWindow::ConfirmDeleteAsync(std::string name) {
  auto body = mxc::TextBlock{};
  // The purpose line answers "can I delete this?" from the app itself
  // (issue #2); the snapshot sentence keeps the recovery path visible.
  body.Text(EntryPurposeHint(name) +
            L"\nA snapshot is taken first and the old value stays "
            L"recoverable from it.");
  body.TextWrapping(mx::TextWrapping::Wrap);
  auto dialog = mxc::ContentDialog{};
  dialog.Title(winrt::box_value(L"Delete " + wide(name) + L"?"));
  dialog.Content(winrt::box_value(body));
  dialog.PrimaryButtonText(L"Delete");
  dialog.CloseButtonText(L"Cancel");
  dialog.DefaultButton(mxc::ContentDialogButton::Close);
  dialog.XamlRoot(Content().XamlRoot());
  auto const choice = co_await dialog.ShowAsync();
  if (choice != mxc::ContentDialogResult::Primary) {
    co_return;
  }
  DeleteEntry(name);
}

winrt::fire_and_forget MainWindow::ConfirmGenerateKeyAsync() {
  if (selected_.empty()) {
    co_return;
  }
  auto body = mxc::TextBlock{};
  body.Text(L"The new pair is collected into the vault directly. Rotating "
            L"the signing key is a release-level change — ship a build "
            L"trusting the new public key first.");
  body.TextWrapping(mx::TextWrapping::Wrap);
  auto dialog = mxc::ContentDialog{};
  dialog.Title(
      winrt::box_value(L"Generate a new Ed25519 update key for " + selected_ +
                       L"?"));
  dialog.Content(winrt::box_value(body));
  dialog.PrimaryButtonText(L"Generate");
  dialog.CloseButtonText(L"Cancel");
  dialog.DefaultButton(mxc::ContentDialogButton::Close);
  dialog.XamlRoot(Content().XamlRoot());
  auto const choice = co_await dialog.ShowAsync();
  if (choice != mxc::ContentDialogResult::Primary) {
    co_return;
  }
  GenerateUpdateKey();
}

winrt::fire_and_forget MainWindow::SnapshotsDialogAsync() {
  auto rows_panel = mxc::StackPanel{};
  rows_panel.Spacing(6);

  // Rebuilds the rows from snapshots_; kept on the window so the
  // LoadSnapshots completion can re-render while the dialog is open.
  snapshot_refresher_ = std::make_shared<std::function<void()>>(
      [weak = get_weak(), rows_panel]() mutable {
        if (auto window = weak.get()) {
          auto children = rows_panel.Children();
          children.Clear();
          if (window->snapshots_.empty()) {
            mxc::TextBlock empty;
            empty.Text(L"No snapshots yet");
            empty.FontSize(13);
            empty.Foreground(DimBrush());
            children.Append(empty);
            return;
          }
          for (auto const& snap : window->snapshots_) {
            mxc::Grid row;
            row.ColumnSpacing(10);
            row.ColumnDefinitions().Append(mxc::ColumnDefinition{});
            row.ColumnDefinitions().Append(mxc::ColumnDefinition{});
            row.ColumnDefinitions().Append(mxc::ColumnDefinition{});
            row.ColumnDefinitions().GetAt(0).Width(
                mx::GridLength{1, mx::GridUnitType::Star});
            row.ColumnDefinitions().GetAt(1).Width(
                mx::GridLength{0, mx::GridUnitType::Auto});
            row.ColumnDefinitions().GetAt(2).Width(
                mx::GridLength{0, mx::GridUnitType::Auto});
            mxc::TextBlock stamp;
            stamp.Text(winrt::to_hstring(snap.stamp));
            stamp.FontSize(12);
            stamp.FontFamily(mx::Media::FontFamily(L"Consolas"));
            stamp.VerticalAlignment(mx::VerticalAlignment::Center);
            mxc::TextBlock size;
            size.Text(winrt::hstring(wide(snap.size) + L" B"));
            size.FontSize(11);
            size.Foreground(DimBrush());
            size.VerticalAlignment(mx::VerticalAlignment::Center);
            auto restore = mxc::Button();
            restore.Content(winrt::box_value(L"Restore"));
            restore.FontSize(11);
            restore.Padding({8, 2, 8, 2});
            restore.VerticalAlignment(mx::VerticalAlignment::Center);
            restore.Click([weak, snap](auto const&, auto const&) {
              if (auto current = weak.get()) {
                current->RestoreSnapshot(snap);
              }
            });
            mxc::Grid::SetColumn(stamp, 0);
            mxc::Grid::SetColumn(size, 1);
            mxc::Grid::SetColumn(restore, 2);
            row.Children().Append(stamp);
            row.Children().Append(size);
            row.Children().Append(restore);
            children.Append(row);
          }
        }
      });

  auto scroller = mxc::ScrollViewer{};
  scroller.MaxHeight(340);
  scroller.Content(rows_panel);
  auto panel = mxc::StackPanel{};
  panel.Spacing(8);
  auto caption = mxc::TextBlock{};
  caption.Text(
      L"Every write lands here first as a plain-text copy in "
      L".history/keyward — restoring takes one click.");
  caption.FontSize(12);
  caption.Foreground(DimBrush());
  panel.Children().Append(caption);
  panel.Children().Append(scroller);

  auto dialog = mxc::ContentDialog{};
  dialog.Title(winrt::box_value(L"Store snapshots"));
  dialog.Content(winrt::box_value(panel));
  dialog.CloseButtonText(L"Done");
  dialog.XamlRoot(Content().XamlRoot());

  (*snapshot_refresher_)();
  LoadSnapshots();
  co_await dialog.ShowAsync();
  snapshot_refresher_ = nullptr;
}

winrt::fire_and_forget MainWindow::OpenVaultPickAsync() {
  auto picker = winrt::Windows::Storage::Pickers::FileOpenPicker{};
  auto window_native = try_as<::IWindowNative>();
  if (window_native) {
    HWND hwnd = nullptr;
    if (SUCCEEDED(window_native->get_WindowHandle(&hwnd))) {
      if (auto initializer = picker.try_as<::IInitializeWithWindow>()) {
        initializer->Initialize(hwnd);
      }
    }
  }
  picker.FileTypeFilter().Append(L".ini");
  picker.FileTypeFilter().Append(L"*");
  auto const file = co_await picker.PickSingleFileAsync();
  if (file != nullptr) {
    OpenStoreAsync(std::wstring(file.Path()));
  }
}

winrt::fire_and_forget MainWindow::ImportKeyPickAsync(std::string name) {
  if (selected_.empty()) {
    co_return;
  }
  auto picker = winrt::Windows::Storage::Pickers::FileOpenPicker{};
  auto window_native = try_as<::IWindowNative>();
  if (window_native) {
    HWND hwnd = nullptr;
    if (SUCCEEDED(window_native->get_WindowHandle(&hwnd))) {
      if (auto initializer = picker.try_as<::IInitializeWithWindow>()) {
        initializer->Initialize(hwnd);
      }
    }
  }
  picker.FileTypeFilter().Append(L".pem");
  picker.FileTypeFilter().Append(L".pub");
  picker.FileTypeFilter().Append(L".crt");
  picker.FileTypeFilter().Append(L".cer");
  picker.FileTypeFilter().Append(L".key");
  picker.FileTypeFilter().Append(L"*");
  auto const file = co_await picker.PickSingleFileAsync();
  if (file != nullptr) {
    ImportKey(name, std::filesystem::path(std::wstring(file.Path())));
  }
}

winrt::fire_and_forget MainWindow::ShowEngineMessage(std::string message) {
  // Reachable from backend reader threads; hop to the UI thread first.
  if (!DispatcherQueue().HasThreadAccess()) {
    auto const dispatcher = DispatcherQueue();
    auto const weak = get_weak();
    dispatcher.TryEnqueue([weak, message = std::move(message)] {
      if (auto window = weak.get()) {
        window->ShowEngineMessage(message);
      }
    });
    co_return;
  }
  SetErrorUi(message);
  auto body = mxc::TextBlock{};
  body.Text(winrt::to_hstring(message));
  body.TextWrapping(mx::TextWrapping::Wrap);
  auto dialog = mxc::ContentDialog{};
  dialog.Title(winrt::box_value(L"Engine message"));
  dialog.Content(winrt::box_value(body));
  dialog.CloseButtonText(L"OK");
  dialog.XamlRoot(Content().XamlRoot());
  co_await dialog.ShowAsync();
}

// ---------------------------------------------------------------------------
// Menu handlers
// ---------------------------------------------------------------------------

void MainWindow::OnChooseVault(
    winrt::Windows::Foundation::IInspectable const&,
    mx::RoutedEventArgs const&) {
  OpenVaultPickAsync();
}

void MainWindow::OnDeepCheck(
    winrt::Windows::Foundation::IInspectable const&,
    mx::RoutedEventArgs const&) {
  CheckAll();
}

void MainWindow::OnSnapshots(
    winrt::Windows::Foundation::IInspectable const&,
    mx::RoutedEventArgs const&) {
  SnapshotsDialogAsync();
}

winrt::fire_and_forget MainWindow::OnAbout(
    winrt::Windows::Foundation::IInspectable const&,
    mx::RoutedEventArgs const&) {
  auto panel = mxc::StackPanel{};
  panel.Spacing(4);
  auto tagline = mxc::TextBlock{};
  tagline.Text(
      L"A signing-key vault over your synced INI file — local by design.\n"
      L"The file and its snapshots are plain text, not encrypted custody.");
  tagline.TextAlignment(mx::TextAlignment::Center);
  tagline.Margin({0, 0, 0, 8});
  auto license = mxc::TextBlock{};
  license.Text(L"Released under the GNU AGPL-3.0");
  license.TextAlignment(mx::TextAlignment::Center);
  license.FontSize(12);
  license.Opacity(0.75);
  auto website = mxc::HyperlinkButton{};
  website.Content(winrt::box_value(L"keyward.jrtx.site"));
  website.NavigateUri(
      winrt::Windows::Foundation::Uri{L"https://keyward.jrtx.site"});
  website.HorizontalAlignment(mx::HorizontalAlignment::Center);
  website.Padding({0, 0, 0, 0});
  auto issue = mxc::HyperlinkButton{};
  issue.Content(winrt::box_value(L"Report an Issue"));
  issue.NavigateUri(winrt::Windows::Foundation::Uri{
      L"https://github.com/turinglambdaai/keyward/issues"});
  issue.HorizontalAlignment(mx::HorizontalAlignment::Center);
  issue.Padding({0, 0, 0, 0});
  panel.Children().Append(tagline);
  panel.Children().Append(license);
  panel.Children().Append(website);
  panel.Children().Append(issue);

  auto dialog = mxc::ContentDialog{};
  // kVersion is a narrow char[] — it must be widened through the UTF-8
  // helper before it joins a wide title (the taskly CI lesson).
  dialog.Title(winrt::box_value(L"Keyward v" + wide(rivet_app::kVersion)));
  dialog.Content(winrt::box_value(panel));
  dialog.CloseButtonText(L"Done");
  dialog.XamlRoot(Content().XamlRoot());
  co_await dialog.ShowAsync();
}

winrt::fire_and_forget MainWindow::OnGuide(
    winrt::Windows::Foundation::IInspectable const&,
    mx::RoutedEventArgs const&) {
  co_await winrt::Windows::System::Launcher::LaunchUriAsync(
      winrt::Windows::Foundation::Uri{
          L"https://github.com/turinglambdaai/keyward/blob/main/docs/"
          L"GUIDE.zh-CN.md"});
}

}  // namespace winrt::RivetHost::implementation
