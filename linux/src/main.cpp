// Keyward Linux host — GTK4 window over one embedded Racket CS backend.
// Functional spec: macos-host/Sources/RivetHost (same 12-RPC surface).
// Boot the runtime off the UI thread; every completion dispatches back to
// the main loop (g_idle_add) before touching widgets. Key values travel
// backend → clipboard only; nothing ever renders them.
#include <gtk/gtk.h>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <type_traits>
#include <vector>

#include "GeneratedBackend.hpp"
#include "system_services.hpp"
#include "theme.hpp"

namespace {

struct ProductInfo {
  std::string name;
  std::string entries;
  std::string key_id;
  std::string fingerprint;
  std::string status;
};

struct EntryRow {
  std::string name;
  std::string state;  // "set" | "empty"
};

struct CheckRow {
  std::string name;
  std::string kind;
  std::string fingerprint;
  std::string paired;
  std::string status;
};

struct SnapshotRow {
  std::string stamp;
  std::string size;
};

constexpr char const* kGuideUrl =
    "https://github.com/turinglambdaai/keyward/blob/main/docs/GUIDE.zh-CN.md";
constexpr char const* kSiteUrl = "https://keyward.jrtx.site";
constexpr char const* kUpdateKeyName = "UPDATE_ED25519_PRIVATE_KEY_B64";

struct AppState {
  GtkWindow* window{nullptr};
  GtkLabel* status{nullptr};
  GtkLabel* store_path{nullptr};
  GtkListBox* product_list{nullptr};
  GtkLabel* sidebar_summary{nullptr};
  GtkBox* detail{nullptr};

  std::unique_ptr<rivet::linux_runtime::Backend> backend;
  std::unique_ptr<rivet_app::API> api;
  std::unique_ptr<rivet::system::Clipboard> clipboard;
  std::mutex startup_mutex;
  std::thread startup_thread;
  std::unique_ptr<rivet::linux_runtime::Backend> startup_backend;
  std::string startup_error;
  std::atomic<bool> shutting_down{false};

  bool ready{false};
  bool suppress_product_signal{false};
  std::string store_path_value;
  std::vector<ProductInfo> products;
  std::vector<CheckRow> checks;
  std::vector<EntryRow> entries;
  std::vector<SnapshotRow> snapshots;
  std::string selected;
  GSimpleAction* deep_check_action{nullptr};
  GSimpleAction* snapshots_action{nullptr};
  // Rows refresher of the open snapshots dialog (null when closed).
  std::function<void()>* snapshot_refresher{nullptr};
};

AppState g_state;

// --- forward declarations (order-independent wiring) -----------------------
void perform_orderly_shutdown();
void dispatch_ui(std::function<void()> run);
void show_engine_message(std::string const& message);
void set_status(std::string const& text);
void rebuild_product_list();
void rebuild_detail();
void set_engine_ready();
void refresh_products(std::function<void()> then);
void bootstrap_store();
void check_all();
void select_product(std::string const& name);
void copy_entry(std::string const& name);
void set_entry(std::string const& name, std::string const& value);
void delete_entry(std::string const& name);
void import_key(std::string const& name, std::string const& file_path);
void generate_update_key();
void load_snapshots();
void restore_snapshot(std::string const& stamp);
void open_store(std::string const& path);
void open_vault_dialog();
void import_key_dialog(std::string const& name);
void show_new_entry_dialog();
void show_delete_confirm(std::string const& name);
void show_generate_confirm();
void show_snapshots_dialog();
void show_about_dialog();
void show_guide();

// ---------------------------------------------------------------------------
// UI dispatch (completions arrive on the backend reader thread)
// ---------------------------------------------------------------------------

struct UiTask {
  std::function<void()> run;
};

int run_ui_task(gpointer user_data) {
  auto* task = static_cast<UiTask*>(user_data);
  task->run();
  delete task;
  return G_SOURCE_REMOVE;
}

void dispatch_ui(std::function<void()> run) {
  g_idle_add(run_ui_task, new UiTask{std::move(run)});
}

template <typename T, typename Then>
void on_result(rivet_app::Result<T> result, Then then) {
  dispatch_ui([result = std::move(result), then = std::move(then)]() mutable {
    if (!result.succeeded()) {
      try {
        std::rethrow_exception(result.error);
      } catch (std::exception const& e) {
        show_engine_message(e.what());
      } catch (...) {
        show_engine_message("unknown backend failure");
      }
      return;
    }
    try {
      if constexpr (std::is_void_v<T>) {
        then();
      } else {
        then(result.value.value());
      }
    } catch (std::exception const& e) {
      show_engine_message(e.what());
    } catch (...) {
      show_engine_message("unknown backend failure");
    }
  });
}

// ---------------------------------------------------------------------------
// Small CSS: dots, chips, cards, mono text (theme-quiet fills, both palettes)
// ---------------------------------------------------------------------------

void install_css() {
  auto* provider = gtk_css_provider_new();
  static char const* css =
      ".kw-dot { font-size: 10px; }\n"
      ".kw-dot-ok { color: #34c759; }\n"
      ".kw-dot-warn { color: #ff9500; }\n"
      ".kw-dot-neutral { color: #8e8e93; }\n"
      ".kw-chip { background: alpha(rgb(128,128,128), 0.16);"
      " border-radius: 6px; padding: 3px 10px; font-size: 12px; }\n"
      ".kw-chip-label { color: alpha(currentColor, 0.55); font-size: 10px;"
      " font-weight: 600; }\n"
      ".kw-chip-ok { color: #34c759; }\n"
      ".kw-chip-warn { color: #ff9500; }\n"
      ".kw-mono { font-family: monospace; }\n"
      ".kw-dim { color: alpha(currentColor, 0.6); }\n"
      ".kw-caption { font-size: 10px; }\n"
      ".kw-empty-badge { color: #ff9500; font-size: 10px;"
      " font-weight: 600; }\n"
      ".kw-title { font-size: 22px; font-weight: 700; }\n"
      ".kw-card { background: alpha(rgb(128,128,128), 0.12);"
      " border-radius: 8px; padding: 9px 12px; }\n"
      ".kw-brand { font-size: 17px; font-weight: 700; }\n";
  gtk_css_provider_load_from_data(provider, css, -1);
  gtk_style_context_add_provider_for_display(
      gdk_display_get_default(), GTK_STYLE_PROVIDER(provider),
      GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  g_object_unref(provider);
}

char const* dot_class_for(std::string const& status) {
  if (status == "ok") return "kw-dot-ok";
  if (status == "no-key" || status == "empty-section" ||
      status.rfind("empty", 0) == 0) {
    return "kw-dot-neutral";
  }
  return "kw-dot-warn";
}

bool status_is_warn(std::string const& status) {
  return std::string(dot_class_for(status)) == "kw-dot-warn";
}

GtkWidget* make_label(char const* text, char const* css_class) {
  auto* label = gtk_label_new(text);
  if (css_class != nullptr) {
    gtk_widget_add_css_class(label, css_class);
  }
  return label;
}

// A chip row cell: "LABEL value" with the value optionally tone-colored.
GtkWidget* make_chip(char const* label, std::string const& value,
                     char const* tone_class) {
  auto* chip = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 5);
  gtk_widget_add_css_class(chip, "kw-chip");
  gtk_box_append(GTK_BOX(chip), make_label(label, "kw-chip-label"));
  gtk_box_append(GTK_BOX(chip),
                 make_label(value.empty() ? "—" : value.c_str(), tone_class));
  return chip;
}

void clear_box(GtkBox* box) {
  while (auto* child = gtk_widget_get_first_child(GTK_WIDGET(box))) {
    gtk_box_remove(box, child);
  }
}

// ---------------------------------------------------------------------------
// Status helpers
// ---------------------------------------------------------------------------

void set_status(std::string const& text) {
  if (g_state.status != nullptr) {
    gtk_label_set_text(g_state.status, text.c_str());
  }
}

void refresh_store_path_label() {
  if (g_state.store_path != nullptr) {
    gtk_label_set_text(g_state.store_path,
                       g_state.store_path_value.c_str());
  }
}

void set_engine_ready() {
  g_state.ready = true;
  bool const armed = !g_state.store_path_value.empty();
  if (g_state.deep_check_action != nullptr) {
    g_simple_action_set_enabled(g_state.deep_check_action, armed);
  }
  if (g_state.snapshots_action != nullptr) {
    g_simple_action_set_enabled(g_state.snapshots_action, armed);
  }
}

void show_engine_message(std::string const& message) {
  if (g_state.window == nullptr) {
    std::fputs((message + "\n").c_str(), stderr);
    return;
  }
  auto* dialog = gtk_message_dialog_new(
      GTK_WINDOW(g_state.window), GTK_DIALOG_MODAL, GTK_MESSAGE_ERROR,
      GTK_BUTTONS_CLOSE, "Engine message");
  gtk_message_dialog_format_secondary_text(GTK_MESSAGE_DIALOG(dialog), "%s",
                                           message.c_str());
  g_signal_connect(
      dialog, "response",
      G_CALLBACK(+[](GtkDialog* dialog, gint, gpointer) {
        gtk_window_destroy(GTK_WINDOW(dialog));
      }),
      nullptr);
  gtk_window_present(GTK_WINDOW(dialog));
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

void rebuild_sidebar_summary() {
  if (g_state.sidebar_summary == nullptr) return;
  auto const paired = std::count_if(
      g_state.products.begin(), g_state.products.end(),
      [](ProductInfo const& p) { return p.status == "ok"; });
  auto const attention = std::count_if(
      g_state.products.begin(), g_state.products.end(),
      [](ProductInfo const& p) { return status_is_warn(p.status); });
  auto text = "Products " + std::to_string(g_state.products.size()) +
              " · Paired " + std::to_string(paired) + " · Attention " +
              std::to_string(attention);
  gtk_label_set_text(g_state.sidebar_summary, text.c_str());
}

void rebuild_product_list() {
  if (g_state.product_list == nullptr) return;
  g_state.suppress_product_signal = true;
  while (auto* row = gtk_list_box_get_row_at_index(g_state.product_list, 0)) {
    gtk_list_box_remove(g_state.product_list, GTK_WIDGET(row));
  }
  for (auto const& product : g_state.products) {
    auto* box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    auto* dot = make_label("●", "kw-dot");
    gtk_widget_add_css_class(dot, dot_class_for(product.status));
    gtk_widget_set_valign(dot, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(box), dot);

    auto* names = gtk_box_new(GTK_ORIENTATION_VERTICAL, 1);
    auto* name = gtk_label_new(product.name.c_str());
    gtk_label_set_ellipsize(GTK_LABEL(name), PANGO_ELLIPSIZE_END);
    gtk_label_set_xalign(GTK_LABEL(name), 0.0f);
    gtk_widget_set_halign(name, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(names), name);
    auto const caption = product.status == "ok" ? product.fingerprint
                                                : product.status;
    auto* caption_label = gtk_label_new(caption.c_str());
    gtk_widget_add_css_class(caption_label, "kw-mono");
    gtk_widget_add_css_class(caption_label, "kw-caption");
    gtk_widget_add_css_class(caption_label, "kw-dim");
    gtk_label_set_ellipsize(GTK_LABEL(caption_label), PANGO_ELLIPSIZE_END);
    gtk_label_set_xalign(GTK_LABEL(caption_label), 0.0f);
    gtk_widget_set_halign(caption_label, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(names), caption_label);
    gtk_widget_set_hexpand(names, TRUE);
    gtk_box_append(GTK_BOX(box), names);

    auto* count = make_label(product.entries.c_str(), "kw-dim");
    gtk_widget_set_valign(count, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(box), count);

    auto* row = gtk_list_box_row_new();
    gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), box);
    g_object_set_data_full(G_OBJECT(row), "product-name",
                           g_strdup(product.name.c_str()), g_free);
    gtk_list_box_append(g_state.product_list, row);
  }
  g_state.suppress_product_signal = false;
  rebuild_sidebar_summary();
}

// Detail pane: no-vault / intro placeholders, or the selected product.
void rebuild_detail() {
  if (g_state.detail == nullptr) return;
  clear_box(g_state.detail);

  if (g_state.store_path_value.empty()) {
    auto* pane = gtk_box_new(GTK_ORIENTATION_VERTICAL, 14);
    gtk_widget_set_valign(pane, GTK_ALIGN_CENTER);
    gtk_widget_set_halign(pane, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_top(pane, 24);
    gtk_widget_set_margin_bottom(pane, 24);
    auto* glyph = make_label("🔑", nullptr);
    gtk_widget_set_opacity(glyph, 0.9);
    auto* title = make_label("No vault selected", "kw-title");
    auto* body = make_label(
        "Point Keyward at your secrets.ini — any vault in the same\n"
        "INI format works. The choice is remembered across launches.",
        "kw-dim");
    gtk_label_set_justify(GTK_LABEL(body), GTK_JUSTIFY_CENTER);
    auto* pick = gtk_button_new_with_label("Choose Vault…");
    gtk_widget_add_css_class(pick, "suggested-action");
    g_signal_connect(
        pick, "clicked",
        G_CALLBACK(+[](GtkButton*, gpointer) { open_vault_dialog(); }),
        nullptr);
    gtk_box_append(GTK_BOX(pane), glyph);
    gtk_box_append(GTK_BOX(pane), title);
    gtk_box_append(GTK_BOX(pane), body);
    gtk_box_append(GTK_BOX(pane), pick);
    gtk_box_append(g_state.detail, pane);
    return;
  }
  if (g_state.selected.empty()) {
    auto* pane = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_valign(pane, GTK_ALIGN_CENTER);
    gtk_widget_set_halign(pane, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_top(pane, 24);
    gtk_widget_set_margin_bottom(pane, 24);
    auto* glyph = make_label("🗝️", nullptr);
    auto* title = make_label("A local vault for release-signing keys",
                             "kw-title");
    auto* body = make_label(
        "Pick a product on the left. Values are never displayed —\n"
        "they only ever leave through copy-to-clipboard.",
        "kw-dim");
    gtk_label_set_justify(GTK_LABEL(body), GTK_JUSTIFY_CENTER);
    gtk_box_append(GTK_BOX(pane), glyph);
    gtk_box_append(GTK_BOX(pane), title);
    gtk_box_append(GTK_BOX(pane), body);
    gtk_box_append(g_state.detail, pane);
    return;
  }

  auto hit = std::find_if(g_state.products.begin(), g_state.products.end(),
                          [](ProductInfo const& p) {
                            return p.name == g_state.selected;
                          });
  if (hit == g_state.products.end()) {
    return;
  }
  auto const& product = *hit;

  auto* root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
  gtk_widget_set_margin_top(root, 20);
  gtk_widget_set_margin_bottom(root, 20);
  gtk_widget_set_margin_start(root, 20);
  gtk_widget_set_margin_end(root, 20);
  gtk_widget_set_valign(root, GTK_ALIGN_START);
  gtk_widget_set_hexpand(root, TRUE);

  // ---- header card ----
  auto* header = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
  gtk_widget_add_css_class(header, "kw-card");
  gtk_box_append(GTK_BOX(header),
                 make_label(product.name.c_str(), "kw-title"));

  auto* info_chips = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  gtk_box_append(GTK_BOX(info_chips),
                 make_chip("ENTRIES", product.entries, nullptr));
  if (!product.key_id.empty()) {
    auto* chip = make_chip("KEY ID", product.key_id, nullptr);
    gtk_box_append(GTK_BOX(info_chips), chip);
  }
  if (!product.fingerprint.empty() && product.fingerprint != "-") {
    auto* chip = make_chip("FINGERPRINT", product.fingerprint, "kw-mono");
    gtk_box_append(GTK_BOX(info_chips), chip);
  }
  gtk_box_append(GTK_BOX(info_chips),
                 make_chip(nullptr, product.status,
                           product.status == "ok"
                               ? "kw-chip-ok"
                               : (status_is_warn(product.status)
                                      ? "kw-chip-warn"
                                      : nullptr)));
  gtk_box_append(GTK_BOX(header), info_chips);

  for (auto const& check : g_state.checks) {
    if (check.name != product.name) continue;
    auto* check_chips = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_box_append(GTK_BOX(check_chips),
                   make_chip("KIND", check.kind, nullptr));
    gtk_box_append(
        GTK_BOX(check_chips),
        make_chip("PAIRED", check.paired,
                  check.paired == "yes" ? "kw-chip-ok" : "kw-chip-warn"));
    gtk_box_append(
        GTK_BOX(check_chips),
        make_chip("CHECK", check.status,
                  check.status == "ok" ? "kw-chip-ok" : "kw-chip-warn"));
    gtk_box_append(GTK_BOX(header), check_chips);
  }
  gtk_box_append(GTK_BOX(root), header);

  // ---- entries section ----
  auto* entries_header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  auto* entries_caption = make_label("Entries", "kw-dim");
  gtk_widget_set_hexpand(entries_caption, TRUE);
  gtk_label_set_xalign(GTK_LABEL(entries_caption), 0.0f);
  gtk_box_append(GTK_BOX(entries_header), entries_caption);

  // Add ▸ menu (New entry / Import PEM / Generate update key).
  auto* add_button = gtk_menu_button_new();
  gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(add_button),
                                "list-add-symbolic");
  gtk_widget_set_tooltip_text(GTK_WIDGET(add_button), "Add");
  auto* add_menu = g_menu_new();
  g_menu_append(add_menu, "New entry…", "win.new-entry");
  g_menu_append(add_menu, "Import PEM file…", "win.import-update-key");
  g_menu_append(add_menu, "Generate update key…", "win.generate-key");
  gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(add_button),
                                 G_MENU_MODEL(add_menu));
  g_object_unref(add_menu);
  gtk_box_append(GTK_BOX(entries_header), add_button);
  gtk_box_append(GTK_BOX(root), entries_header);

  if (g_state.entries.empty()) {
    gtk_box_append(GTK_BOX(root),
                   make_label("No entries in this section.", "kw-dim"));
  }

  for (auto const& entry : g_state.entries) {
    auto* row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    gtk_widget_add_css_class(row, "kw-card");

    auto* lock =
        make_label(entry.state == "set" ? "🔒" : "🔓", nullptr);
    gtk_widget_set_valign(lock, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(row), lock);

    auto* name = gtk_label_new(entry.name.c_str());
    gtk_widget_add_css_class(name, "kw-mono");
    gtk_label_set_ellipsize(GTK_LABEL(name), PANGO_ELLIPSIZE_END);
    gtk_label_set_xalign(GTK_LABEL(name), 0.0f);
    gtk_widget_set_hexpand(name, TRUE);
    gtk_widget_set_valign(name, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(row), name);

    if (entry.state == "empty") {
      auto* badge = make_label("empty", "kw-empty-badge");
      gtk_widget_set_valign(badge, GTK_ALIGN_CENTER);
      gtk_box_append(GTK_BOX(row), badge);
    }

    auto* copy = gtk_button_new_with_label("Copy");
    gtk_widget_set_valign(copy, GTK_ALIGN_CENTER);
    g_object_set_data_full(G_OBJECT(copy), "entry-name",
                           g_strdup(entry.name.c_str()), g_free);
    g_signal_connect(
        copy, "clicked",
        G_CALLBACK(+[](GtkButton* button, gpointer) {
          if (auto const* name = static_cast<char const*>(
                  g_object_get_data(G_OBJECT(button), "entry-name"))) {
            copy_entry(name);
          }
        }),
        nullptr);
    gtk_box_append(GTK_BOX(row), copy);

    // ⋯ menu: copy / import PEM / delete (parameterized window actions).
    auto* more = gtk_menu_button_new();
    gtk_menu_button_set_label(GTK_MENU_BUTTON(more), "⋯");
    gtk_widget_set_valign(more, GTK_ALIGN_CENTER);
    auto* menu = g_menu_new();
    auto* copy_item = g_menu_item_new("Copy value to clipboard", nullptr);
    g_menu_item_set_action_and_target(copy_item, "win.copy-entry", "s",
                                      entry.name.c_str());
    g_menu_append_item(menu, copy_item);
    g_object_unref(copy_item);
    auto* import_item = g_menu_item_new("Import PEM file…", nullptr);
    g_menu_item_set_action_and_target(import_item, "win.import-entry", "s",
                                      entry.name.c_str());
    g_menu_append_item(menu, import_item);
    g_object_unref(import_item);
    auto* delete_item = g_menu_item_new("Delete…", nullptr);
    g_menu_item_set_action_and_target(delete_item, "win.delete-entry", "s",
                                      entry.name.c_str());
    g_menu_append_item(menu, delete_item);
    g_object_unref(delete_item);
    gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(more),
                                   G_MENU_MODEL(menu));
    g_object_unref(menu);
    gtk_box_append(GTK_BOX(row), more);

    gtk_box_append(GTK_BOX(root), row);
  }

  gtk_box_append(g_state.detail, root);
}

// ---------------------------------------------------------------------------
// File dialogs (GTK 4.10 GtkFileDialog; portal-backed when available)
// ---------------------------------------------------------------------------

void open_vault_dialog() {
  auto* dialog = gtk_file_dialog_new();
  gtk_file_dialog_set_title(dialog, "Choose Vault");
  auto* filter = gtk_file_filter_new();
  gtk_file_filter_set_name(filter, "INI vault");
  gtk_file_filter_add_pattern(filter, "*.ini");
  auto* filters = g_list_store_new(GTK_TYPE_FILE_FILTER);
  g_list_store_append(filters, filter);
  g_object_unref(filter);
  gtk_file_dialog_set_filters(dialog, G_LIST_MODEL(filters));
  g_object_unref(filters);
  gtk_file_dialog_open(
      dialog, GTK_WINDOW(g_state.window), nullptr,
      +[](GObject* source, GAsyncResult* result, gpointer) {
        GError* error = nullptr;
        GFile* file = gtk_file_dialog_open_finish(GTK_FILE_DIALOG(source),
                                                  result, &error);
        if (file != nullptr) {
          gchar* path = g_file_get_path(file);
          if (path != nullptr) {
            open_store(path);
            g_free(path);
          }
          g_object_unref(file);
        }
        if (error != nullptr) g_error_free(error);
        g_object_unref(GTK_FILE_DIALOG(source));
      },
      nullptr);
}

void import_key_dialog(std::string const& name) {
  if (g_state.selected.empty()) return;
  auto* dialog = gtk_file_dialog_new();
  gtk_file_dialog_set_title(dialog, "Import PEM file");
  auto* filters = g_list_store_new(GTK_TYPE_FILE_FILTER);
  for (char const* pattern : {".pem", ".pub", ".crt", ".cer", ".key"}) {
    auto* filter = gtk_file_filter_new();
    gtk_file_filter_set_name(filter, pattern + 1);
    gtk_file_filter_add_pattern(filter, (std::string("*") + pattern).c_str());
    g_list_store_append(filters, filter);
    g_object_unref(filter);
  }
  gtk_file_dialog_set_filters(dialog, G_LIST_MODEL(filters));
  g_object_unref(filters);
  gtk_file_dialog_open(
      dialog, GTK_WINDOW(g_state.window), nullptr,
      +[](GObject* source, GAsyncResult* result, gpointer user_data) {
        std::unique_ptr<std::string> const name(
            static_cast<std::string*>(user_data));
        GError* error = nullptr;
        GFile* file = gtk_file_dialog_open_finish(GTK_FILE_DIALOG(source),
                                                  result, &error);
        if (file != nullptr) {
          gchar* path = g_file_get_path(file);
          if (path != nullptr) {
            import_key(*name, path);
            g_free(path);
          }
          g_object_unref(file);
        }
        if (error != nullptr) g_error_free(error);
        g_object_unref(GTK_FILE_DIALOG(source));
      },
      new std::string(name));
}

// ---------------------------------------------------------------------------
// Dialogs
// ---------------------------------------------------------------------------

void show_new_entry_dialog() {
  if (g_state.selected.empty()) return;
  auto* dialog = gtk_dialog_new_with_buttons(
      ("New entry in " + g_state.selected).c_str(),
      GTK_WINDOW(g_state.window),
      static_cast<GtkDialogFlags>(GTK_DIALOG_MODAL |
                                  GTK_DIALOG_DESTROY_WITH_PARENT),
      "_Cancel", GTK_RESPONSE_CANCEL, "_Set", GTK_RESPONSE_OK, nullptr);
  gtk_window_set_default_size(GTK_WINDOW(dialog), 420, -1);

  auto* content = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
  gtk_box_set_spacing(GTK_BOX(content), 8);
  gtk_widget_set_margin_top(content, 12);
  gtk_widget_set_margin_bottom(content, 6);
  gtk_widget_set_margin_start(content, 12);
  gtk_widget_set_margin_end(content, 12);

  auto* name_entry = gtk_entry_new();
  gtk_entry_set_placeholder_text(GTK_ENTRY(name_entry), "NAME");
  auto* value_entry = gtk_entry_new();
  gtk_entry_set_placeholder_text(GTK_ENTRY(value_entry),
                                 "value (single line)");
  gtk_box_append(GTK_BOX(content), name_entry);
  gtk_box_append(GTK_BOX(content), value_entry);
  g_object_set_data_full(G_OBJECT(dialog), "name-entry",
                         g_object_ref(name_entry), g_object_unref);
  g_object_set_data_full(G_OBJECT(dialog), "value-entry",
                         g_object_ref(value_entry), g_object_unref);

  g_signal_connect(
      dialog, "response",
      G_CALLBACK(+[](GtkDialog* dialog, gint response, gpointer) {
        if (response == GTK_RESPONSE_OK) {
          auto* name_entry = GTK_ENTRY(
              g_object_get_data(G_OBJECT(dialog), "name-entry"));
          auto* value_entry = GTK_ENTRY(
              g_object_get_data(G_OBJECT(dialog), "value-entry"));
          auto const* raw = gtk_editable_get_text(GTK_EDITABLE(name_entry));
          std::string name(raw == nullptr ? "" : raw);
          std::transform(name.begin(), name.end(), name.begin(),
                         [](unsigned char c) { return std::toupper(c); });
          auto const* value =
              gtk_editable_get_text(GTK_EDITABLE(value_entry));
          if (!name.empty()) {
            set_entry(name, value == nullptr ? "" : value);
          }
        }
        gtk_window_destroy(GTK_WINDOW(dialog));
      }),
      nullptr);
  gtk_window_present(GTK_WINDOW(dialog));
}

void show_delete_confirm(std::string const& name) {
  auto* dialog = gtk_message_dialog_new(
      GTK_WINDOW(g_state.window), GTK_DIALOG_MODAL, GTK_MESSAGE_QUESTION,
      GTK_BUTTONS_OK_CANCEL, "Delete %s?", name.c_str());
  gtk_message_dialog_format_secondary_text(
      GTK_MESSAGE_DIALOG(dialog),
      "A snapshot is taken first and the old value stays recoverable from "
      "it.");
  g_signal_connect(
      dialog, "response",
      G_CALLBACK(+[](GtkDialog* dialog, gint response, gpointer) {
        if (response == GTK_RESPONSE_OK) {
          auto const* name = static_cast<char const*>(
              g_object_get_data(G_OBJECT(dialog), "entry-name"));
          if (name != nullptr) {
            delete_entry(name);
          }
        }
        gtk_window_destroy(GTK_WINDOW(dialog));
      }),
      nullptr);
  g_object_set_data_full(G_OBJECT(dialog), "entry-name", g_strdup(name.c_str()),
                         g_free);
  gtk_window_present(GTK_WINDOW(dialog));
}

void show_generate_confirm() {
  if (g_state.selected.empty()) return;
  auto* dialog = gtk_message_dialog_new(
      GTK_WINDOW(g_state.window), GTK_DIALOG_MODAL, GTK_MESSAGE_WARNING,
      GTK_BUTTONS_OK_CANCEL,
      "Generate a new Ed25519 update key for %s?", g_state.selected.c_str());
  gtk_message_dialog_format_secondary_text(
      GTK_MESSAGE_DIALOG(dialog),
      "The new pair is collected into the vault directly. Rotating the "
      "signing key is a release-level change — ship a build trusting the new "
      "public key first.");
  g_signal_connect(
      dialog, "response",
      G_CALLBACK(+[](GtkDialog* dialog, gint response, gpointer) {
        if (response == GTK_RESPONSE_OK) {
          generate_update_key();
        }
        gtk_window_destroy(GTK_WINDOW(dialog));
      }),
      nullptr);
  gtk_window_present(GTK_WINDOW(dialog));
}

void on_snapshot_dialog_destroy(gpointer data) {
  delete static_cast<std::function<void()>*>(data);
  g_state.snapshot_refresher = nullptr;
}

void show_snapshots_dialog() {
  if (g_state.api == nullptr) return;
  auto* dialog = gtk_dialog_new_with_buttons(
      "Store snapshots", GTK_WINDOW(g_state.window),
      static_cast<GtkDialogFlags>(GTK_DIALOG_MODAL |
                                  GTK_DIALOG_DESTROY_WITH_PARENT |
                                  GTK_DIALOG_USE_HEADER_BAR),
      "_Done", GTK_RESPONSE_CLOSE, nullptr);
  gtk_window_set_default_size(GTK_WINDOW(dialog), 560, 420);

  auto* content = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
  gtk_box_set_spacing(GTK_BOX(content), 8);
  gtk_widget_set_margin_top(content, 12);
  gtk_widget_set_margin_bottom(content, 12);
  gtk_widget_set_margin_start(content, 12);
  gtk_widget_set_margin_end(content, 12);
  gtk_box_append(
      GTK_BOX(content),
      make_label("Every write lands here first — restoring takes one click.",
                 "kw-dim"));

  auto* rows = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
  auto* scroller = gtk_scrolled_window_new();
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), rows);
  gtk_widget_set_vexpand(scroller, TRUE);
  gtk_box_append(GTK_BOX(content), scroller);

  // Rows refresher: rebuilds from g_state.snapshots_. load_snapshots()
  // calls it whenever a fresh list lands while the dialog is open.
  auto* refresher = new std::function<void()>([rows]() {
    clear_box(GTK_BOX(rows));
    if (g_state.snapshots.empty()) {
      gtk_box_append(GTK_BOX(rows),
                     make_label("No snapshots yet", "kw-dim"));
      return;
    }
    for (auto const& snap : g_state.snapshots) {
      auto* row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
      gtk_widget_add_css_class(row, "kw-card");
      auto* stamp = gtk_label_new(snap.stamp.c_str());
      gtk_widget_add_css_class(stamp, "kw-mono");
      gtk_widget_set_hexpand(stamp, TRUE);
      gtk_label_set_xalign(GTK_LABEL(stamp), 0.0f);
      gtk_widget_set_valign(stamp, GTK_ALIGN_CENTER);
      gtk_box_append(GTK_BOX(row), stamp);
      auto* size = make_label((snap.size + " B").c_str(), "kw-dim");
      gtk_widget_set_valign(size, GTK_ALIGN_CENTER);
      gtk_box_append(GTK_BOX(row), size);
      auto* restore = gtk_button_new_with_label("Restore");
      gtk_widget_set_valign(restore, GTK_ALIGN_CENTER);
      g_object_set_data_full(G_OBJECT(restore), "snapshot-stamp",
                             g_strdup(snap.stamp.c_str()), g_free);
      g_signal_connect(
          restore, "clicked",
          G_CALLBACK(+[](GtkButton* button, gpointer) {
            if (auto const* stamp = static_cast<char const*>(
                    g_object_get_data(G_OBJECT(button), "snapshot-stamp"))) {
              restore_snapshot(stamp);
            }
          }),
          nullptr);
      gtk_box_append(GTK_BOX(row), restore);
      gtk_box_append(GTK_BOX(rows), row);
    }
  });
  g_state.snapshot_refresher = refresher;
  g_object_set_data_full(G_OBJECT(dialog), "snapshot-refresher", refresher,
                         on_snapshot_dialog_destroy);

  g_signal_connect(
      dialog, "response",
      G_CALLBACK(+[](GtkDialog* dialog, gint, gpointer) {
        gtk_window_destroy(GTK_WINDOW(dialog));
      }),
      nullptr);
  gtk_window_present(GTK_WINDOW(dialog));
  (*refresher)();
  load_snapshots();
}

void show_about_dialog() {
  auto* dialog = gtk_about_dialog_new();
  gtk_about_dialog_set_program_name(GTK_ABOUT_DIALOG(dialog), "Keyward");
  gtk_about_dialog_set_version(GTK_ABOUT_DIALOG(dialog),
                               rivet_app::kVersion);
  gtk_about_dialog_set_comments(
      GTK_ABOUT_DIALOG(dialog),
      "A signing-key vault over your synced INI file — local by design.");
  gtk_about_dialog_set_license(GTK_ABOUT_DIALOG(dialog),
                               "Released under the GNU AGPL-3.0");
  gtk_about_dialog_set_website(GTK_ABOUT_DIALOG(dialog), kSiteUrl);
  gtk_about_dialog_set_website_label(GTK_ABOUT_DIALOG(dialog),
                                     "keyward.jrtx.site");
  gtk_window_set_transient_for(GTK_WINDOW(dialog), GTK_WINDOW(g_state.window));
  gtk_window_set_modal(GTK_WINDOW(dialog), TRUE);
  gtk_window_present(GTK_WINDOW(dialog));
}

void show_guide() {
  // GtkUriLauncher (4.10+) — the non-deprecated sibling of GtkFileDialog.
  auto* launcher = gtk_uri_launcher_new(kGuideUrl);
  gtk_uri_launcher_launch(
      launcher, GTK_WINDOW(g_state.window), nullptr,
      +[](GObject* source, GAsyncResult* result, gpointer) {
        GError* error = nullptr;
        gtk_uri_launcher_launch_finish(GTK_URI_LAUNCHER(source), result,
                                       &error);
        if (error != nullptr) g_error_free(error);
        g_object_unref(GTK_URI_LAUNCHER(source));
      },
      nullptr);
}

// ---------------------------------------------------------------------------
// RPC flows (all completions dispatch back through dispatch_ui)
// ---------------------------------------------------------------------------

void refresh_products(std::function<void()> then) {
  if (g_state.api == nullptr) return;
  (void)g_state.api->store_info_async(
      [then = std::move(then)](
          rivet_app::Result<std::vector<std::vector<std::string>>> result) {
        on_result(std::move(result),
                  [then = std::move(then)](
                      std::vector<std::vector<std::string>> const& rows) {
                    g_state.products.clear();
                    for (auto const& row : rows) {
                      ProductInfo info;
                      if (!row.empty()) info.name = row[0];
                      if (row.size() > 1) info.entries = row[1];
                      if (row.size() > 2) info.key_id = row[2];
                      if (row.size() > 3) info.fingerprint = row[3];
                      if (row.size() > 4) info.status = row[4];
                      g_state.products.push_back(std::move(info));
                    }
                    if (!g_state.selected.empty()) {
                      auto hit = std::find_if(
                          g_state.products.begin(), g_state.products.end(),
                          [](ProductInfo const& p) {
                            return p.name == g_state.selected;
                          });
                      if (hit == g_state.products.end()) {
                        g_state.selected.clear();
                        g_state.entries.clear();
                      }
                    }
                    rebuild_product_list();
                    rebuild_detail();
                    if (then) {
                      then();
                    }
                  });
      });
}

void bootstrap_store() {
  if (g_state.api == nullptr) return;
  (void)g_state.api->store_path_async(
      [](rivet_app::Result<std::string> result) {
        on_result(std::move(result), [](std::string const& path) {
          g_state.store_path_value = path;
          refresh_store_path_label();
          set_engine_ready();
          rebuild_product_list();
          rebuild_detail();
          refresh_products([] {
            set_status("Connected — " +
                       std::to_string(g_state.products.size()) +
                       " products");
          });
        });
      });
}

void check_all() {
  if (g_state.api == nullptr || !g_state.ready ||
      g_state.store_path_value.empty()) {
    return;
  }
  (void)g_state.api->check_store_async(
      [](rivet_app::Result<std::vector<std::vector<std::string>>> result) {
        on_result(std::move(result),
                  [](std::vector<std::vector<std::string>> const& rows) {
                    g_state.checks.clear();
                    for (auto const& row : rows) {
                      // The "(file)" row is the whole-file report;
                      // per-product check chips come from the sections.
                      if (row.empty() || row[0] == "(file)") continue;
                      CheckRow check;
                      check.name = row[0];
                      if (row.size() > 4) check.kind = row[4];
                      if (row.size() > 5) check.fingerprint = row[5];
                      if (row.size() > 6) check.paired = row[6];
                      if (row.size() > 7) check.status = row[7];
                      g_state.checks.push_back(std::move(check));
                    }
                    rebuild_detail();
                    set_status("Deep check finished — " +
                               std::to_string(g_state.checks.size()) +
                               " sections");
                  });
      });
}

void select_product(std::string const& name) {
  g_state.selected = name;
  g_state.entries.clear();
  rebuild_product_list();
  rebuild_detail();
  if (g_state.api == nullptr) return;
  (void)g_state.api->entry_list_async(
      name,
      [](rivet_app::Result<std::vector<std::vector<std::string>>> result) {
        on_result(std::move(result),
                  [](std::vector<std::vector<std::string>> const& rows) {
                    g_state.entries.clear();
                    for (auto const& row : rows) {
                      EntryRow entry;
                      if (!row.empty()) entry.name = row[0];
                      if (row.size() > 1) entry.state = row[1];
                      g_state.entries.push_back(std::move(entry));
                    }
                    rebuild_detail();
                  });
      });
}

void copy_entry(std::string const& name) {
  if (g_state.api == nullptr || g_state.selected.empty()) return;
  (void)g_state.api->entry_get_async(
      g_state.selected, name,
      [name](rivet_app::Result<std::string> result) {
        on_result(std::move(result), [name](std::string const& value) {
          // The value's only way out: clipboard, never the screen.
          if (g_state.clipboard != nullptr) {
            g_state.clipboard->write_text(value);
          }
          set_status("Copied " + name + " — value stays off-screen");
        });
      });
}

void set_entry(std::string const& name, std::string const& value) {
  if (g_state.api == nullptr || g_state.selected.empty()) return;
  (void)g_state.api->entry_set_async(
      g_state.selected, name, value,
      [name](rivet_app::Result<std::string> result) {
        on_result(std::move(result), [name](std::string const& summary) {
          set_status("Set " + name + " — " + summary);
          select_product(g_state.selected);
        });
      });
}

void delete_entry(std::string const& name) {
  if (g_state.api == nullptr || g_state.selected.empty()) return;
  (void)g_state.api->entry_delete_async(
      g_state.selected, name,
      [name](rivet_app::Result<bool> result) {
        on_result(std::move(result), [name](bool) {
          set_status("Deleted " + name + " (snapshot taken)");
          select_product(g_state.selected);
        });
      });
}

void import_key(std::string const& name, std::string const& file_path) {
  if (g_state.api == nullptr || g_state.selected.empty()) return;
  (void)g_state.api->entry_import_file_async(
      g_state.selected, name, file_path,
      [name](rivet_app::Result<std::string> result) {
        on_result(std::move(result), [name](std::string const& summary) {
          set_status("Imported " + name + " — " + summary);
          select_product(g_state.selected);
        });
      });
}

void generate_update_key() {
  if (g_state.api == nullptr || g_state.selected.empty()) return;
  (void)g_state.api->keypair_generate_async(
      g_state.selected,
      [](rivet_app::Result<std::vector<std::string>> result) {
        on_result(
            std::move(result),
            [](std::vector<std::string> const& row) {
              auto const key_id = row.empty() ? "" : row[0];
              auto const fingerprint = row.size() > 1 ? row[1] : "";
              set_status("Generated " + key_id + " — fingerprint " +
                         fingerprint + " (collected into the vault)");
              select_product(g_state.selected);
            });
      });
}

void load_snapshots() {
  if (g_state.api == nullptr) return;
  (void)g_state.api->snapshot_list_async(
      [](rivet_app::Result<std::vector<std::vector<std::string>>> result) {
        on_result(std::move(result),
                  [](std::vector<std::vector<std::string>> const& rows) {
                    g_state.snapshots.clear();
                    for (auto const& row : rows) {
                      SnapshotRow snap;
                      if (!row.empty()) snap.stamp = row[0];
                      if (row.size() > 1) snap.size = row[1];
                      g_state.snapshots.push_back(std::move(snap));
                    }
                    if (g_state.snapshot_refresher != nullptr) {
                      (*g_state.snapshot_refresher)();
                    }
                  });
      });
}

void restore_snapshot(std::string const& stamp) {
  if (g_state.api == nullptr) return;
  (void)g_state.api->snapshot_restore_async(
      stamp,
      [stamp](rivet_app::Result<bool> result) {
        on_result(std::move(result), [stamp](bool) {
          set_status("Restored " + stamp + " (pre-restore snapshot taken)");
          refresh_products(nullptr);
        });
      });
}

void open_store(std::string const& path) {
  if (g_state.api == nullptr) return;
  (void)g_state.api->store_open_async(
      path,
      [](rivet_app::Result<std::string> result) {
        on_result(std::move(result), [](std::string const& opened) {
          g_state.store_path_value = opened;
          refresh_store_path_label();
          g_state.products.clear();
          g_state.selected.clear();
          g_state.checks.clear();
          g_state.entries.clear();
          rebuild_product_list();
          rebuild_detail();
          refresh_products(nullptr);
          set_status("Store switched: " + opened);
        });
      });
}

// ---------------------------------------------------------------------------
// GAction menu + accelerators
// ---------------------------------------------------------------------------

void add_window_action(GtkApplicationWindow* window, char const* name,
                       void (*handler)(GSimpleAction*, GVariant*, gpointer),
                       GVariantType const* parameter_type = nullptr) {
  auto* action = g_simple_action_new(name, parameter_type);
  g_signal_connect(action, "activate", G_CALLBACK(handler), nullptr);
  g_action_map_add_action(G_ACTION_MAP(window), G_ACTION(action));
  g_object_unref(action);
}

GSimpleAction* add_tracked_window_action(
    GtkApplicationWindow* window, char const* name,
    void (*handler)(GSimpleAction*, GVariant*, gpointer)) {
  auto* action = g_simple_action_new(name, nullptr);
  g_signal_connect(action, "activate", G_CALLBACK(handler), nullptr);
  g_action_map_add_action(G_ACTION_MAP(window), G_ACTION(action));
  g_object_unref(action);  // the action map holds its own reference
  return action;
}

void on_action_choose_vault(GSimpleAction*, GVariant*, gpointer) {
  open_vault_dialog();
}
void on_action_deep_check(GSimpleAction*, GVariant*, gpointer) { check_all(); }
void on_action_snapshots(GSimpleAction*, GVariant*, gpointer) {
  show_snapshots_dialog();
}
void on_action_about(GSimpleAction*, GVariant*, gpointer) {
  show_about_dialog();
}
void on_action_guide(GSimpleAction*, GVariant*, gpointer) { show_guide(); }
void on_action_new_entry(GSimpleAction*, GVariant*, gpointer) {
  show_new_entry_dialog();
}
void on_action_import_update_key(GSimpleAction*, GVariant*, gpointer) {
  import_key_dialog(kUpdateKeyName);
}
void on_action_generate_key(GSimpleAction*, GVariant*, gpointer) {
  show_generate_confirm();
}
void on_action_copy_entry(GSimpleAction*, GVariant* parameter, gpointer) {
  if (parameter != nullptr) {
    copy_entry(g_variant_get_string(parameter, nullptr));
  }
}
void on_action_import_entry(GSimpleAction*, GVariant* parameter, gpointer) {
  if (parameter != nullptr) {
    import_key_dialog(g_variant_get_string(parameter, nullptr));
  }
}
void on_action_delete_entry(GSimpleAction*, GVariant* parameter, gpointer) {
  if (parameter != nullptr) {
    show_delete_confirm(g_variant_get_string(parameter, nullptr));
  }
}

void install_actions_and_menu(GtkApplication* app,
                              GtkApplicationWindow* window) {
  add_window_action(window, "choose-vault", on_action_choose_vault);
  g_state.deep_check_action = add_tracked_window_action(
      window, "deep-check", on_action_deep_check);
  g_state.snapshots_action = add_tracked_window_action(
      window, "snapshots", on_action_snapshots);
  add_window_action(window, "about", on_action_about);
  add_window_action(window, "guide", on_action_guide);
  add_window_action(window, "new-entry", on_action_new_entry);
  add_window_action(window, "import-update-key", on_action_import_update_key);
  add_window_action(window, "generate-key", on_action_generate_key);
  add_window_action(window, "copy-entry", on_action_copy_entry,
                    G_VARIANT_TYPE_STRING);
  add_window_action(window, "import-entry", on_action_import_entry,
                    G_VARIANT_TYPE_STRING);
  add_window_action(window, "delete-entry", on_action_delete_entry,
                    G_VARIANT_TYPE_STRING);

  // Accelerators mirror the macOS host: ⌘O choose vault, ⌘R deep check,
  // ⌘L snapshots.
  static char const* const accels_choose_vault[] = {"<Control>o", nullptr};
  static char const* const accels_deep_check[] = {"<Control>r", nullptr};
  static char const* const accels_snapshots[] = {"<Control>l", nullptr};
  gtk_application_set_accels_for_action(app, "win.choose-vault",
                                        accels_choose_vault);
  gtk_application_set_accels_for_action(app, "win.deep-check",
                                        accels_deep_check);
  gtk_application_set_accels_for_action(app, "win.snapshots",
                                        accels_snapshots);
}

GMenu* build_header_menu() {
  auto* menu = g_menu_new();
  g_menu_append(menu, "Choose Vault…", "win.choose-vault");
  auto* vault_section = g_menu_new();
  g_menu_append(vault_section, "Deep Check", "win.deep-check");
  g_menu_append(vault_section, "Snapshots", "win.snapshots");
  g_menu_append_section(menu, nullptr, G_MENU_MODEL(vault_section));
  g_object_unref(vault_section);
  auto* help_section = g_menu_new();
  g_menu_append(help_section, "User Guide — 使用手册", "win.guide");
  g_menu_append(help_section, "About Keyward", "win.about");
  g_menu_append_section(menu, nullptr, G_MENU_MODEL(help_section));
  g_object_unref(help_section);
  return menu;
}

// ---------------------------------------------------------------------------
// Product selection wiring
// ---------------------------------------------------------------------------

void on_product_row_selected(GtkListBox*, GtkListBoxRow* row, gpointer) {
  if (g_state.suppress_product_signal || row == nullptr) return;
  auto const* name =
      static_cast<char const*>(g_object_get_data(G_OBJECT(row),
                                                 "product-name"));
  if (name != nullptr) {
    select_product(name);
  }
}

// ---------------------------------------------------------------------------
// Startup (same contract as the Rivet template)
// ---------------------------------------------------------------------------

void perform_orderly_shutdown();

std::filesystem::path executable_path() {
  return std::filesystem::read_symlink("/proc/self/exe");
}

// Rivet keeps runtime/res beside the executable in development and packages.
struct RuntimeLayout {
  std::filesystem::path petite_boot;
  std::filesystem::path scheme_boot;
  std::filesystem::path racket_boot;
  std::filesystem::path core;
};

std::optional<RuntimeLayout> discover_runtime_layout() {
  std::filesystem::path const exe = executable_path();
  std::filesystem::path const roots[] = {exe.parent_path()};
  for (auto const& root : roots) {
    RuntimeLayout layout{
        root / "runtime" / "petite.boot",
        root / "runtime" / "scheme.boot",
        root / "runtime" / "racket.boot",
        root / "res" / "core.zo",
    };
    if (std::filesystem::exists(layout.petite_boot) &&
        std::filesystem::exists(layout.scheme_boot) &&
        std::filesystem::exists(layout.racket_boot) &&
        std::filesystem::exists(layout.core)) {
      return layout;
    }
  }
  return std::nullopt;
}

int on_backend_finished(gpointer) {
  if (g_state.startup_thread.joinable()) {
    g_state.startup_thread.join();
  }

  std::unique_ptr<rivet::linux_runtime::Backend> backend;
  std::string error;
  {
    std::lock_guard lock(g_state.startup_mutex);
    backend = std::move(g_state.startup_backend);
    error = std::move(g_state.startup_error);
  }

  if (g_state.shutting_down.load(std::memory_order_acquire)) {
    if (backend != nullptr) {
      backend->stop();
    }
    return G_SOURCE_REMOVE;
  }

  if (!error.empty()) {
    set_status("Backend error: " + error);
    return G_SOURCE_REMOVE;
  }
  if (backend == nullptr) {
    set_status("Backend error: startup completed without a backend");
    return G_SOURCE_REMOVE;
  }

  g_state.backend = std::move(backend);
  g_state.api = std::make_unique<rivet_app::API>(*g_state.backend);
  // Plain-text clipboard through the GTK display (rivet's adapter; compiled
  // into this build per linux/CMakeLists.txt).
  g_state.clipboard = std::make_unique<rivet::system::Clipboard>();

  // racket_boot installs Racket CS signal handlers. Install Rivet's process
  // shutdown bridge after the Hello handshake so SIGTERM/SIGINT keep reaching
  // the native application's orderly close path.
  try {
    rivet::system::InstallShutdownHook(perform_orderly_shutdown);
  } catch (std::exception const& hook_error) {
    std::fputs((std::string{"shutdown hook unavailable: "} +
                hook_error.what() + "\n")
                   .c_str(),
               stderr);
  }

  set_status("Starting embedded Racket CS…");
  bootstrap_store();
  return G_SOURCE_REMOVE;
}

void start_backend() {
  auto layout = discover_runtime_layout();
  if (!layout.has_value()) {
    set_status(
        "Missing Rivet runtime layout (runtime/*.boot, res/core.zo) next to "
        "the executable. Build with raco rivet build/dev.");
    return;
  }

  rivet::linux_runtime::RacketRuntimeConfig config;
  config.executable_path = executable_path().string();
  config.petite_boot = layout->petite_boot.string();
  config.scheme_boot = layout->scheme_boot.string();
  config.racket_boot = layout->racket_boot.string();
  config.backend_bundle = layout->core.string();
  config.module_name = rivet_app::kModuleName;
  config.entry_symbol = rivet_app::kEntryName;

  // Booting the embedded runtime blocks on file I/O; only startup runs off
  // the main loop. Everything after completion dispatches back through
  // g_idle_add.
  g_state.startup_thread = std::thread([config = std::move(config)]() mutable {
    auto backend =
        std::make_unique<rivet::linux_runtime::Backend>(std::move(config));
    try {
      backend->start();
      {
        std::lock_guard lock(g_state.startup_mutex);
        g_state.startup_backend = std::move(backend);
      }
    } catch (std::exception const& e) {
      std::lock_guard lock(g_state.startup_mutex);
      g_state.startup_error = e.what();
    }
    g_idle_add(on_backend_finished, nullptr);
  });
}

void on_activate(GtkApplication* app, gpointer) {
  if (g_state.window != nullptr) {
    gtk_window_present(g_state.window);
    return;
  }

  // Plain GTK4 can receive a portal color scheme that disagrees with the
  // selected theme-name variant. Pin both before creating widgets so native
  // controls and application CSS cannot render on opposite palettes.
  (void)rivet::linux_ui::ApplyTheme();
  install_css();

  auto* window = gtk_application_window_new(app);
  gtk_window_set_title(GTK_WINDOW(window), "Keyward");
  gtk_window_set_default_size(GTK_WINDOW(window), 1000, 680);
  g_state.window = GTK_WINDOW(window);

  // Header bar with the primary menu (Choose Vault / Deep Check /
  // Snapshots / guide / About — same surface as the macOS menus).
  auto* header = gtk_header_bar_new();
  auto* title = make_label("Keyward", "kw-brand");
  gtk_header_bar_set_title_widget(GTK_HEADER_BAR(header), title);
  auto* menu_button = gtk_menu_button_new();
  gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(menu_button),
                                "open-menu-symbolic");
  gtk_widget_set_tooltip_text(GTK_WIDGET(menu_button), "Main menu");
  auto* menu = build_header_menu();
  gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(menu_button),
                                 G_MENU_MODEL(menu));
  g_object_unref(menu);
  gtk_header_bar_pack_end(GTK_HEADER_BAR(header), menu_button);
  gtk_window_set_titlebar(GTK_WINDOW(window), header);

  // Body: products sidebar | detail pane, over a status bar.
  auto* root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  auto* body = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
  gtk_widget_set_vexpand(body, TRUE);

  auto* sidebar = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
  gtk_widget_set_margin_top(sidebar, 10);
  gtk_widget_set_margin_bottom(sidebar, 10);
  gtk_widget_set_margin_start(sidebar, 10);
  gtk_widget_set_margin_end(sidebar, 10);
  gtk_widget_set_size_request(sidebar, 240, -1);

  auto* brand_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
  gtk_box_append(GTK_BOX(brand_box), make_label("Keyward", "kw-brand"));
  gtk_box_append(GTK_BOX(brand_box),
                 make_label("release-signing key vault", "kw-dim"));
  gtk_box_append(GTK_BOX(sidebar), brand_box);

  g_state.sidebar_summary =
      GTK_LABEL(make_label("Products 0 · Paired 0 · Attention 0", "kw-dim"));
  gtk_box_append(GTK_BOX(sidebar), GTK_WIDGET(g_state.sidebar_summary));

  g_state.product_list = GTK_LIST_BOX(gtk_list_box_new());
  gtk_list_box_set_selection_mode(g_state.product_list, GTK_SELECTION_SINGLE);
  g_signal_connect(g_state.product_list, "row-selected",
                   G_CALLBACK(on_product_row_selected), nullptr);
  auto* list_scroller = gtk_scrolled_window_new();
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(list_scroller),
                                GTK_WIDGET(g_state.product_list));
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(list_scroller),
                                 GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_widget_set_vexpand(list_scroller, TRUE);
  gtk_box_append(GTK_BOX(sidebar), list_scroller);

  auto* detail_scroller = gtk_scrolled_window_new();
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(detail_scroller),
                                 GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC);
  g_state.detail = GTK_BOX(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0));
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(detail_scroller),
                                GTK_WIDGET(g_state.detail));
  gtk_widget_set_hexpand(detail_scroller, TRUE);

  gtk_paned_set_start_child(GTK_PANED(body), sidebar);
  gtk_paned_set_shrink_start_child(GTK_PANED(body), FALSE);
  gtk_paned_set_end_child(GTK_PANED(body), detail_scroller);
  gtk_paned_set_shrink_end_child(GTK_PANED(body), FALSE);
  gtk_paned_set_position(GTK_PANED(body), 280);
  gtk_box_append(GTK_BOX(root), body);

  // Status bar: engine/operation message left, vault path right.
  auto* status_bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
  gtk_widget_set_margin_top(status_bar, 6);
  gtk_widget_set_margin_bottom(status_bar, 6);
  gtk_widget_set_margin_start(status_bar, 12);
  gtk_widget_set_margin_end(status_bar, 12);
  g_state.status =
      GTK_LABEL(make_label("Starting embedded Racket CS…", "kw-dim"));
  gtk_label_set_ellipsize(g_state.status, PANGO_ELLIPSIZE_END);
  gtk_label_set_xalign(g_state.status, 0.0f);
  gtk_widget_set_hexpand(GTK_WIDGET(g_state.status), TRUE);
  gtk_box_append(GTK_BOX(status_bar), GTK_WIDGET(g_state.status));
  g_state.store_path = GTK_LABEL(make_label("", "kw-mono"));
  gtk_widget_add_css_class(GTK_WIDGET(g_state.store_path), "kw-dim");
  gtk_label_set_ellipsize(g_state.store_path, PANGO_ELLIPSIZE_START);
  gtk_box_append(GTK_BOX(status_bar), GTK_WIDGET(g_state.store_path));
  gtk_box_append(GTK_BOX(root), status_bar);

  gtk_window_set_child(GTK_WINDOW(window), root);
  install_actions_and_menu(app, GTK_APPLICATION_WINDOW(window));
  gtk_window_present(GTK_WINDOW(window));
  start_backend();
}

void on_shutdown(GApplication*, gpointer) {
  g_state.shutting_down.store(true, std::memory_order_release);
  if (g_state.startup_thread.joinable()) {
    g_state.startup_thread.join();
  }

  std::unique_ptr<rivet::linux_runtime::Backend> startup_backend;
  {
    std::lock_guard lock(g_state.startup_mutex);
    startup_backend = std::move(g_state.startup_backend);
  }
  if (startup_backend != nullptr) {
    startup_backend->stop();
  }
  if (g_state.backend != nullptr) {
    g_state.backend->stop();
  }
}

// SIGTERM/SIGINT bypass the GTK main loop, so the shutdown signal handler
// alone would leave the window alive over a dead backend. The watcher
// thread runs this same cleanup and then hard-exits; keep it synchronous
// and allocation-light.
void perform_orderly_shutdown() { on_shutdown(nullptr, nullptr); }

}  // namespace

int main(int argc, char** argv) {
  g_set_application_name("Keyward");
  auto* app =
      gtk_application_new(rivet_app::kIdentifier, G_APPLICATION_DEFAULT_FLAGS);
  g_signal_connect(app, "activate", G_CALLBACK(on_activate), nullptr);
  g_signal_connect(app, "shutdown", G_CALLBACK(on_shutdown), nullptr);
  int const status = g_application_run(G_APPLICATION(app), argc, argv);
  g_object_unref(app);
  return status;
}
