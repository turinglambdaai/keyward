#pragma once

#include "pch.h"
#include "MainWindow.g.h"
#include "system_services.hpp"
#include "winui_window.hpp"

namespace winrt::RivetHost::implementation {

struct MainWindow : MainWindowT<MainWindow> {
  MainWindow();

  // Stable HWND access for platform-owned features such as global hotkeys,
  // clipboard listeners, window subclassing, topmost policy, and tray icons.
  [[nodiscard]] HWND WindowHandle() {
    return rivet::system::NativeWindowHandle(*this);
  }

  // Thread-safe orderly backend stop shared by the window-close path and
  // the console-control shutdown hook (logoff/CTRL events).
  void StopBackendOrderly();

  // Menu handlers
  void OnChooseVault(winrt::Windows::Foundation::IInspectable const&,
                     Microsoft::UI::Xaml::RoutedEventArgs const&);
  void OnDeepCheck(winrt::Windows::Foundation::IInspectable const&,
                   Microsoft::UI::Xaml::RoutedEventArgs const&);
  void OnSnapshots(winrt::Windows::Foundation::IInspectable const&,
                   Microsoft::UI::Xaml::RoutedEventArgs const&);
  void OnScanStrayKeys(winrt::Windows::Foundation::IInspectable const&,
                       Microsoft::UI::Xaml::RoutedEventArgs const&);
  winrt::fire_and_forget OnAbout(
      winrt::Windows::Foundation::IInspectable const&,
      Microsoft::UI::Xaml::RoutedEventArgs const&);
  winrt::fire_and_forget OnGuide(
      winrt::Windows::Foundation::IInspectable const&,
      Microsoft::UI::Xaml::RoutedEventArgs const&);

 private:
  // Rows exactly as the engine returns them (app/backend.rkt header comment).
  struct ProductInfo {
    std::wstring name;
    std::wstring entries;
    std::wstring key_id;
    std::wstring fingerprint;
    std::wstring status;
  };
  struct EntryRow {
    std::string name;
    std::string state;
  };
  struct CheckRow {
    std::wstring name;
    std::wstring kind;
    std::wstring fingerprint;
    std::wstring paired;
    std::wstring status;
  };
  struct SnapshotRow {
    std::string stamp;
    std::string size;
  };
  // Rotation staging state for the selected product — identifiers and
  // fingerprints only, straight from `rotation-status`.
  struct RotationState {
    std::wstring next_present;
    std::wstring next_paired;
    std::wstring next_fingerprint;
    std::wstring next_key_id;
    std::wstring active_fingerprint;
    std::wstring active_key_id;
  };
  // One stray-key scan hit: path, 1-based line, kind, fingerprint — values
  // never.
  struct StrayRow {
    std::wstring path;
    std::wstring line;
    std::wstring kind;
    std::wstring fingerprint;
  };

  winrt::fire_and_forget InitializeBackendAsync();

  // Status-bar message lines.
  void SetReadyUi();
  void SetErrorUi(std::string const& message);
  void SetStatusMessage(std::wstring const& message);

  // RPC flows. Every completion hops through the DispatcherQueue before it
  // touches XAML state; the backend is captured by value so a window closed
  // mid-call never destroys the last reference on a reader thread.
  void BootstrapStore();
  void RefreshProducts(std::function<void()> then);
  void CheckAll();
  void SelectProduct(std::wstring const& name);
  void CopyEntry(EntryRow const& entry);
  void ScheduleClipboardExpiry();
  void SetEntry(std::wstring const& name, std::wstring const& value);
  void DeleteEntry(std::string const& name);
  void ImportKey(std::string const& name,
                 std::filesystem::path const& file_path);
  void GenerateUpdateKey();
  void LoadSnapshots();
  void RestoreSnapshot(SnapshotRow const& snap);
  void OpenStoreAsync(std::wstring const& path);
  // Two-phase rotation (the runbook): stage next, promote, discard; the
  // status row drives the Rotation card's chips and affordances.
  void RefreshRotation();
  void StageNextKey();
  void PromoteNextKey();
  void DiscardNextKey();
  // Working-tree stray-key scan: folder pick + results dialog.
  void RunStrayScan(std::wstring const& path);
  // Clipboard-only export of an entry in an updater-native format.
  void CopyExport(EntryRow const& entry, std::string format);

  // Rendering (plain rebuild — the row counts are vault-scale small).
  void RenderSidebar();
  void RenderDetail();
  winrt::Microsoft::UI::Xaml::UIElement MakeEntryCard(EntryRow const& entry);

  // Dialogs and pickers.
  winrt::fire_and_forget NewEntryDialogAsync();
  winrt::fire_and_forget ConfirmDeleteAsync(std::string name);
  winrt::fire_and_forget ConfirmGenerateKeyAsync();
  winrt::fire_and_forget ConfirmStageKeyAsync();
  winrt::fire_and_forget ConfirmPromoteKeyAsync();
  winrt::fire_and_forget ConfirmDiscardKeyAsync();
  winrt::fire_and_forget SnapshotsDialogAsync();
  winrt::fire_and_forget StrayScanDialogAsync();
  winrt::fire_and_forget OpenVaultPickAsync();
  winrt::fire_and_forget ScanFolderPickAsync();
  winrt::fire_and_forget ImportKeyPickAsync(std::string name);
  winrt::fire_and_forget ShowEngineMessage(std::string message);

  bool ready_{false};
  std::shared_ptr<rivet::windows::Backend> backend_;
  std::vector<ProductInfo> products_;
  std::vector<CheckRow> checks_;
  std::vector<EntryRow> entries_;
  std::vector<SnapshotRow> snapshots_;
  std::vector<StrayRow> stray_rows_;
  RotationState rotation_{};
  std::wstring selected_;
  std::wstring store_path_;
  // Bumped on every selection change; async entry/copy completions carry
  // the generation they were issued under and are dropped when stale, so
  // rows and copy targets always bind to the product on screen (issue #3).
  unsigned selection_generation_{0};
  // Owns the pending 30 s clipboard expiry. Restarted on every copy; the
  // tick clears the clipboard only when it still holds our copy (checked
  // through a non-secret marker property), so a later unrelated copy by
  // the user is never erased.
  winrt::Microsoft::UI::Dispatching::DispatcherQueueTimer
      clipboard_expiry_timer_{nullptr};
  // While the snapshots dialog is open, LoadSnapshots completions re-render
  // its rows through this (also fires on the first load, which lands after
  // the dialog is already up).
  std::shared_ptr<std::function<void()>> snapshot_refresher_;
  // The open new-entry dialog, held only while it is on screen. Projected
  // XAML types have no get_weak, so the TextChanged handler reaches the
  // dialog through this member (cleared on close) instead of capturing it
  // — a strong capture would cycle dialog → panel → name_box → dialog.
  winrt::Microsoft::UI::Xaml::Controls::ContentDialog pending_entry_dialog_{
      nullptr};
};

}  // namespace winrt::RivetHost::implementation

namespace winrt::RivetHost::factory_implementation {

struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow> {};

}  // namespace winrt::RivetHost::factory_implementation
