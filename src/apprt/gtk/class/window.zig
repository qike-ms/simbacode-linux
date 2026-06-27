const std = @import("std");
const build_config = @import("../../../build_config.zig");
const assert = @import("../../../quirks.zig").inlineAssert;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const i18n = @import("../../../os/main.zig").i18n;
const apprt = @import("../../../apprt.zig");
const configpkg = @import("../../../config.zig");
const TitlebarStyle = configpkg.Config.GtkTitlebarStyle;
const input = @import("../../../input.zig");
const CoreSurface = @import("../../../Surface.zig");
const ext = @import("../ext.zig");
const gtk_version = @import("../gtk_version.zig");
const adw_version = @import("../adw_version.zig");
const gresource = @import("../build/gresource.zig");
const winprotopkg = @import("../winproto.zig");
const Common = @import("../class.zig").Common;
const Config = @import("config.zig").Config;
const Application = @import("application.zig").Application;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const SplitTree = @import("split_tree.zig").SplitTree;
const Surface = @import("surface.zig").Surface;
const Tab = @import("tab.zig").Tab;
const sidebar = @import("sidebar.zig");
const sidebar_store = @import("sidebar_store.zig");
const agentpkg = @import("agent.zig");
const DebugWarning = @import("debug_warning.zig").DebugWarning;
const CommandPalette = @import("command_palette.zig").CommandPalette;
const WeakRef = @import("../weak_ref.zig").WeakRef;

const log = std.log.scoped(.gtk_ghostty_window);

pub const Window = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.ApplicationWindow;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyWindow",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The active surface is the focus that should be receiving all
        /// surface-targeted actions. This is usually the focused surface,
        /// but may also not be focused if the user has selected a non-surface
        /// widget.
        pub const @"active-surface" = struct {
            pub const name = "active-surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface,
                        .{
                            .getter = Self.getActiveSurface,
                        },
                    ),
                },
            );
        };

        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };

        pub const debug = struct {
            pub const name = "debug";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = build_config.is_debug,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = struct {
                            pub fn getter(_: *Self) bool {
                                return build_config.is_debug;
                            }
                        }.getter,
                    }),
                },
            );
        };

        pub const @"titlebar-style" = struct {
            pub const name = "titlebar-style";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                TitlebarStyle,
                .{
                    .default = .native,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        TitlebarStyle,
                        .{
                            .getter = Self.getTitlebarStyle,
                        },
                    ),
                },
            );
        };

        pub const @"headerbar-visible" = struct {
            pub const name = "headerbar-visible";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getHeaderbarVisible,
                    }),
                },
            );
        };

        pub const @"quick-terminal" = struct {
            pub const name = "quick-terminal";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "quick_terminal",
                    ),
                },
            );
        };

        pub const @"tabs-autohide" = struct {
            pub const name = "tabs-autohide";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsAutohide,
                    }),
                },
            );
        };

        pub const @"tabs-wide" = struct {
            pub const name = "tabs-wide";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsWide,
                    }),
                },
            );
        };

        pub const @"tabs-visible" = struct {
            pub const name = "tabs-visible";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsVisible,
                    }),
                },
            );
        };

        pub const @"toolbar-style" = struct {
            pub const name = "toolbar-style";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                adw.ToolbarStyle,
                .{
                    .default = .raised,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        adw.ToolbarStyle,
                        .{
                            .getter = Self.getToolbarStyle,
                        },
                    ),
                },
            );
        };
    };

    const Private = struct {
        /// Tag for a sidebar ListBox row: either a collapsible repo header or a
        /// worktree leaf. `index` indexes into `sidebar_statuses` for worktree
        /// rows, or is the index of the repo's FIRST worktree for header rows
        /// (used to read repo_root/repo_name for collapse toggling).
        pub const SidebarRowRef = struct {
            kind: enum { active_header, active_card, repo_header, worktree },
            index: usize,
        };

        /// Supacode (#22): an agent recorded on a surface, plus the worktree
        /// path that owned the surface at attach time (or null for the default
        /// space / menu tabs). The path is captured while the surface is live
        /// so teardown never walks a half-destroyed ancestry.
        pub const AgentEntry = struct {
            agent: agentpkg.Agent,
            /// Owned NUL-terminated worktree path, or null for the default space.
            path: ?[:0]u8,
            /// The agent's current activity, set by OSC-3008 busy/idle/
            /// awaiting_input events. Mirrors AgentPresenceFeature.Activity:
            /// busy = working, idle = waiting, awaiting_input = needs the user.
            activity: agentpkg.Activity = .idle,
            /// The agent's LOCAL process id, carried in `pid=` only when the
            /// hook ran on the same host (gated on SUPACODE_SOCKET_PATH in the
            /// emit; omitted over SSH). Null means "no local pid to track". The
            /// liveness sweep reaps this entry when a non-null pid is dead, so a
            /// crashed local agent that never sent session_end is cleaned up.
            /// Mirrors AgentPresenceFeature.PresenceRecord.pids + livenessSweep.
            pid: ?std.posix.pid_t = null,
        };

        /// Supacode (#22): aggregate agent presence for one worktree path.
        pub const WorktreeAgents = struct {
            /// Number of live agent surfaces under this worktree.
            count: u32 = 0,
            /// A representative agent for the Active card icon.
            agent: agentpkg.Agent,
        };

        /// Supacode (#11): one entry in the notification bell history. Owns its
        /// strings; freed in `clearNotifications` / dispose.
        pub const Notification = struct {
            /// Owned NUL-terminated worktree path the event came from. Used to
            /// navigate to that worktree when the popover row is activated.
            path: [:0]u8,
            /// Owned display text (agent label + first line of detail).
            text: [:0]u8,
            /// Whether the user has seen this (drives the unread badge).
            read: bool = false,

            pub fn deinit(self: *const Notification, alloc: std.mem.Allocator) void {
                alloc.free(self.path);
                alloc.free(self.text);
            }
        };

        /// Whether this window is a quick terminal. If it is then it
        /// behaves slightly differently under certain scenarios.
        quick_terminal: bool = false,

        /// The window decoration override. If this is not set then we'll
        /// inherit whatever the config has. This allows overriding the
        /// config on a per-window basis.
        window_decoration: ?configpkg.WindowDecoration = null,

        /// Binding group for our active tab.
        tab_bindings: *gobject.BindingGroup,

        /// The configuration that this surface is using.
        config: ?*Config = null,

        /// State and logic for windowing protocol for a window.
        winproto: winprotopkg.Window,

        /// Kind of hacky to have this but this lets us know if we've
        /// initialized any single surface yet. We need this because we
        /// gate default size on this so that we don't resize the window
        /// after surfaces already exist.
        ///
        /// I think long term we can probably get rid of this by implementing
        /// a property or method that gets us all the surfaces in all the
        /// tabs and checking if we have zero or one that isn't initialized.
        ///
        /// For now, this logic is more similar to our legacy GTK side.
        surface_init: bool = false,

        /// See tabOverviewOpen for why we have this.
        tab_overview_focus_timer: ?c_uint = null,

        /// Supacode worktree sidebar: repeating poll timer (5s) that rescans
        /// the projects root for git worktree status.
        sidebar_timer: ?c_uint = null,

        /// Supacode liveness-sweep timer. Periodically reaps agent presence
        /// whose attributed local pid is dead — closing the deferred
        /// agent-crash-TTL item. Mirrors AgentPresenceFeature.livenessSweep
        /// (a 2s periodic kill(pid, 0) check). Removed in dispose.
        liveness_timer: ?c_uint = null,

        /// The most recent worktree scan, owned by this window. Indexed by
        /// ListBox row index for row-activation -> open-worktree mapping.
        sidebar_statuses: []sidebar.WorktreeStatus = &.{},

        /// Supacode (#21): user-curated set of project roots persisted to
        /// `~/.supacode/sidebar.json`. The sidebar scans ONLY these roots —
        /// never a blanket `~/git` walk. Loaded on startup; written on
        /// add/remove. Empty on first run (no auto-import).
        sidebar_store: sidebar_store.Store = .{},

        /// Surfaces currently flagged as "needs attention" by an OSC-3008
        /// attention signal, mapped to their worktree path (owned/duped). The
        /// sidebar bell for a path is shown when ANY surface with that path is
        /// in this map, so two tabs/surfaces sharing a worktree don't clear
        /// each other's attention (trio MAJOR M2). Keyed by *Surface pointer.
        sidebar_attention: std.AutoHashMapUnmanaged(*Surface, [:0]u8) = .empty,

        /// Set of repo roots whose worktree group is collapsed in the sidebar.
        /// Keys are owned (duped). Persists across the 5s rescan so the user's
        /// expand/collapse choice is sticky.
        sidebar_collapsed: std.StringHashMapUnmanaged(void) = .empty,

        /// Parallel mapping from ListBox row index -> what that row represents
        /// (a repo header, or a worktree by index into sidebar_statuses).
        /// Rebuilt on every refresh. Owned by this window.
        sidebar_rows: std.ArrayListUnmanaged(SidebarRowRef) = .empty,

        /// Supacode agent presence: maps a surface (by pointer, stable identity)
        /// to the agent attached to it plus the worktree path that owned the
        /// surface at attach time. Populated by OSC-3008 `agent=<name>`
        /// metadata; cleared on `end` or surface teardown. The owning path is
        /// captured while the surface is still live so teardown never has to
        /// walk a half-destroyed widget ancestry (#22 / trio CRITICAL). Keyed
        /// by surface pointer so two tabs sharing a worktree don't collide.
        surface_agents: std.AutoHashMapUnmanaged(*Surface, AgentEntry) = .empty,

        /// Supacode (#22): per-worktree-path agent count + a representative
        /// agent for the "Active" card icon. Maintained incrementally as agents
        /// attach/detach (when surfaces are live), so `rebuildSidebarRows` is
        /// an O(1) lookup per worktree and never touches widget ancestry. Keys
        /// are owned (duped path); an entry exists iff its count > 0.
        worktree_agents: std.StringHashMapUnmanaged(WorktreeAgents) = .empty,

        /// The surface the agent attention banner currently points at, so the
        /// banner's "Open" button can teleport focus there (trio: close the
        /// loop — signal -> one-click jump to the waiting agent).
        agent_banner_surface: ?*Surface = null,

        /// Supacode (#11): notification history backing the toolbar bell
        /// popover. Each record is an aggregated agent attention event. The
        /// banner is transient; this list is the persistent history.
        notifications: std.ArrayListUnmanaged(Notification) = .empty,

        /// A weak reference to a command palette.
        command_palette: WeakRef(CommandPalette) = .empty,

        /// Tab page that the context menu was opened for.
        /// setup by `setup-menu`.
        context_menu_page: ?*adw.TabPage = null,

        // Template bindings
        tab_overview: *adw.TabOverview,
        tab_bar: *adw.TabBar,
        tab_view: *adw.TabView,
        toolbar: *adw.ToolbarView,
        toast_overlay: *adw.ToastOverlay,
        split_view: *adw.OverlaySplitView,
        sidebar_list: *gtk.ListBox,
        sidebar_add_button: *gtk.Button,
        agent_banner: *adw.Banner,

        /// Supacode (#10): title-bar repo + user identity chip widgets.
        identity_chip: *gtk.Box,
        identity_avatar: *adw.Avatar,
        identity_branch: *gtk.Label,
        identity_repo: *gtk.Label,

        /// Supacode (#11): notification bell button + popover widgets.
        notification_button: *gtk.MenuButton,
        notification_list: *gtk.ListBox,
        notification_empty: *gtk.Label,
        notification_clear_button: *gtk.Button,

        /// Supacode per-worktree tab spaces (#7, Option A): a Gtk.Stack holding
        /// one Adw.TabView per worktree path. Selecting a worktree in the
        /// sidebar swaps the visible TabView (and repoints tab_bar / overview)
        /// so each folder owns its own set of tabs, matching macOS supacode
        /// (Worktree.ID -> [TerminalTabID]). The template `tab_view` is the
        /// DEFAULT view used for menu-opened tabs with no worktree.
        worktree_stack: *gtk.Stack,

        /// Per-worktree TabViews keyed by owned (duped) worktree path. The
        /// template tab_view is registered here under the empty-string key as
        /// the default. Freed in dispose().
        worktree_views: std.StringHashMapUnmanaged(*adw.TabView) = .empty,

        /// Set true at the start of dispose() so per-view signal handlers
        /// (notify::n-pages firing as the stack tears down its children) don't
        /// re-enter window-close logic during teardown (#7 review: dispose
        /// re-entrancy).
        disposing: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(
        app: *Application,
        overrides: struct {
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) *Self {
        const win = gobject.ext.newInstance(Self, .{
            .application = app,
        });

        if (overrides.title) |title| {
            // If the overrides have a title set, we set that immediately
            // so that any applications inspecting the window states see an
            // immediate title set when the window appears, rather than waiting
            // possibly a few event loop ticks for it to sync from the surface.
            win.as(gtk.Window).setTitle(title);
        }

        return win;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // If our configuration is null then we get the configuration
        // from the application.
        const priv = self.private();

        const config = config: {
            if (priv.config) |config| break :config config.get();
            const app = Application.default();
            const config = app.getConfig();
            priv.config = config;
            break :config config.get();
        };

        // We initialize our windowing protocol to none because we can't
        // actually initialize this until we get realized.
        priv.winproto = .none;

        // Add our dev CSS class if we're in debug mode.
        if (comptime build_config.is_debug) {
            self.as(gtk.Widget).addCssClass("devel");
        }

        // Setup our tab binding group. This ensures certain properties
        // are only synced from the currently active tab.
        priv.tab_bindings = gobject.BindingGroup.new();
        priv.tab_bindings.bind("title", self.as(gobject.Object), "title", .{});

        // Supacode (#7): register the template tab_view as the default tab
        // space so per-worktree view bookkeeping has a consistent fallback.
        self.registerDefaultWorktreeView();

        // Set our window icon. We can't set this in the blueprint file
        // because its dependent on the build config.
        self.as(gtk.Window).setIconName(build_config.bundle_id);

        // Initialize our actions
        self.initActionMap();

        // Start states based on config.
        if (config.maximize) self.as(gtk.Window).maximize();
        if (config.fullscreen != .false) self.as(gtk.Window).fullscreen();

        // If we have an explicit title set, we set that immediately
        // so that any applications inspecting the window states see
        // an immediate title set when the window appears, rather than
        // waiting possibly a few event loop ticks for it to sync from
        // the surface.
        if (config.title) |title| {
            self.as(gtk.Window).setTitle(title);
        }

        // We always sync our appearance at the end because loading our
        // config and such can affect our bindings which are setup initially
        // in initTemplate.
        self.syncAppearance();

        // We need to do this so that the title initializes properly,
        // I think because its a dynamic getter.
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }

    /// Setup our action map.
    fn initActionMap(self: *Self) void {
        const s_variant_type = glib.ext.VariantType.newFor([:0]const u8);
        defer s_variant_type.free();

        const actions = [_]ext.actions.Action(Self){
            .init("about", actionAbout, null),
            .init("close", actionClose, null),
            .init("close-tab", actionCloseTab, s_variant_type),
            .init("new-tab", actionNewTab, null),
            .init("new-window", actionNewWindow, null),
            .init("prompt-surface-title", actionPromptSurfaceTitle, null),
            .init("prompt-tab-title", actionPromptTabTitle, null),
            .init("prompt-context-tab-title", actionPromptContextTabTitle, null),
            .init("ring-bell", actionRingBell, null),
            .init("split-right", actionSplitRight, null),
            .init("split-left", actionSplitLeft, null),
            .init("split-up", actionSplitUp, null),
            .init("split-down", actionSplitDown, null),
            .init("copy", actionCopy, null),
            .init("paste", actionPaste, null),
            .init("reset", actionReset, null),
            .init("clear", actionClear, null),
            // TODO: accept the surface that toggled the command palette
            .init("toggle-command-palette", actionToggleCommandPalette, null),
            .init("toggle-inspector", actionToggleInspector, null),
        };

        ext.actions.add(Self, self, &actions);
    }

    /// Winproto backend for this window.
    pub fn winproto(self: *Self) *winprotopkg.Window {
        return &self.private().winproto;
    }

    /// Create a new tab with the given parent. The tab will be inserted
    /// at the position dictated by the `window-new-tab-position` config.
    /// The new tab will be selected.
    pub fn newTab(self: *Self, parent_: ?*CoreSurface) void {
        _ = self.newTabPage(parent_, .tab, .none);
    }

    pub fn newTabForWindow(
        self: *Self,
        parent_: ?*CoreSurface,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) void {
        _ = self.newTabPage(
            parent_,
            .window,
            .{
                .command = overrides.command,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
            },
        );
    }

    fn newTabPage(
        self: *Self,
        parent_: ?*CoreSurface,
        context: apprt.surface.NewSurfaceContext,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) *adw.TabPage {
        const priv: *Private = self.private();
        const tab_view = self.activeTabView();

        // Create our new tab object
        const tab = Tab.new(
            priv.config,
            .{
                .command = overrides.command,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
            },
        );

        if (parent_) |p| {
            // For a new window's first tab, inherit the parent's initial size hints.
            if (context == .window) {
                surfaceInit(p.rt_surface.gobj(), self);
            }
            tab.setParentWithContext(p, context);
        }

        // Get the position that we should insert the new tab at.
        const config = if (priv.config) |v| v.get() else {
            // If we don't have a config we just append it at the end.
            // This should never happen.
            return tab_view.append(tab.as(gtk.Widget));
        };
        const position = switch (config.@"window-new-tab-position") {
            .current => current: {
                const selected = tab_view.getSelectedPage() orelse
                    break :current tab_view.getNPages();
                const current = tab_view.getPagePosition(selected);
                break :current current + 1;
            },

            .end => tab_view.getNPages(),
        };

        // Add the page and select it
        const page = tab_view.insert(tab.as(gtk.Widget), position);
        tab_view.setSelectedPage(page);

        // Create some property bindings
        _ = tab.as(gobject.Object).bindProperty(
            "title",
            page.as(gobject.Object),
            "title",
            .{ .sync_create = true },
        );
        _ = tab.as(gobject.Object).bindProperty(
            "tooltip",
            page.as(gobject.Object),
            "tooltip",
            .{ .sync_create = true },
        );

        // Bind signals
        const split_tree = tab.getSplitTree();
        _ = SplitTree.signals.changed.connect(
            split_tree,
            *Self,
            tabSplitTreeChanged,
            self,
            .{},
        );

        // Refresh the tab's agent indicator icon when focus moves between
        // panes of a split (stage-8, trio M4/claude m5). The icon shows the
        // FOCUSED surface's agent; without this it only updated on OSC events,
        // so focusing a different pane left the previous pane's icon shown.
        _ = gobject.Object.signals.notify.connect(
            tab,
            *Self,
            tabActiveSurfaceChanged,
            self,
            .{ .detail = "active-surface" },
        );

        // Run an initial notification for the surface tree so we can setup
        // initial state.
        tabSplitTreeChanged(
            split_tree,
            null,
            split_tree.getTree(),
            self,
        );

        return page;
    }

    pub const SelectTab = union(enum) {
        previous,
        next,
        last,
        n: usize,
    };

    /// Select the tab as requested. Returns true if the tab selection
    /// changed.
    pub fn selectTab(self: *Self, n: SelectTab) bool {
        const tab_view = self.activeTabView();

        // Get our current tab numeric position
        const selected = tab_view.getSelectedPage() orelse return false;
        const current = tab_view.getPagePosition(selected);

        // Get our total
        const total = tab_view.getNPages();

        const goto: c_int = switch (n) {
            .previous => if (current > 0)
                current - 1
            else
                total - 1,

            .next => if (current < total - 1)
                current + 1
            else
                0,

            .last => total - 1,

            .n => |v| n: {
                // 1-indexed
                if (v == 0) return false;

                const n_int = std.math.cast(
                    c_int,
                    v,
                ) orelse return false;
                break :n @min(n_int - 1, total - 1);
            },
        };
        assert(goto >= 0);
        assert(goto < total);

        // If our target is the same as our current then we do nothing.
        if (goto == current) return false;

        // Add the page and select it
        const page = tab_view.getNthPage(goto);
        tab_view.setSelectedPage(page);

        return true;
    }

    /// Move the tab containing the given surface by the given amount.
    /// Returns if this affected any tab positioning.
    pub fn moveTab(
        self: *Self,
        surface: *Surface,
        amount: isize,
    ) bool {
        const tab_view = self.activeTabView();

        // If we have one tab we never move.
        const total = tab_view.getNPages();
        if (total == 1) return false;

        // Get the tab that contains the given surface.
        const tab = ext.getAncestor(
            Tab,
            surface.as(gtk.Widget),
        ) orelse return false;

        // Get the page position that contains the tab.
        const page = tab_view.getPage(tab.as(gtk.Widget));
        const pos = tab_view.getPagePosition(page);

        // Move it
        const desired_pos: c_int = desired: {
            const initial: c_int = @intCast(pos + amount);
            const max = total - 1;
            break :desired if (initial < 0)
                max + initial + 1
            else if (initial > max)
                initial - max - 1
            else
                initial;
        };
        assert(desired_pos >= 0);
        assert(desired_pos < total);

        return tab_view.reorderPage(page, desired_pos) != 0;
    }

    pub fn toggleTabOverview(self: *Self) void {
        const priv = self.private();
        const tab_overview = priv.tab_overview;
        const is_open = tab_overview.getOpen() != 0;
        tab_overview.setOpen(@intFromBool(!is_open));
    }

    /// Toggle the visible property.
    pub fn toggleVisibility(self: *Self) void {
        const widget = self.as(gtk.Widget);
        widget.setVisible(@intFromBool(widget.isVisible() == 0));
    }

    /// Updates various appearance properties. This should always be safe
    /// to call multiple times. This should be called whenever a change
    /// happens that might affect how the window appears (config change,
    /// fullscreen, etc.).
    fn syncAppearance(self: *Self) void {
        const priv = self.private();
        const widget = self.as(gtk.Widget);

        // Toggle style classes based on whether we're using CSDs or SSDs.
        //
        // These classes are defined in the gtk.Window documentation:
        // https://docs.gtk.org/gtk4/class.Window.html#css-nodes.
        {
            // Reset all style classes first
            inline for (&.{
                "ssd",
                "csd",
                "solid-csd",
                "no-border-radius",
            }) |class|
                widget.removeCssClass(class);

            const csd_enabled = priv.winproto.clientSideDecorationEnabled();
            self.as(gtk.Window).setDecorated(@intFromBool(csd_enabled));

            if (csd_enabled) {
                const display = widget.getDisplay();

                // We do the exact same check GTK is doing internally and toggle
                // either the `csd` or `solid-csd` style, based on whether the user's
                // window manager is deemed _non-compositing_.
                //
                // In practice this only impacts users of traditional X11 window
                // managers (e.g. i3, dwm, awesomewm, etc.) and not X11 desktop
                // environments or Wayland compositors/DEs.
                if (display.isRgba() != 0 and display.isComposited() != 0) {
                    widget.addCssClass("csd");
                } else {
                    widget.addCssClass("solid-csd");
                }
            } else {
                widget.addCssClass("ssd");
                // Fix any artifacting that may occur in window corners.
                widget.addCssClass("no-border-radius");
            }
        }

        // Trigger all our dynamic properties that depend on the config.
        inline for (&.{
            "headerbar-visible",
            "tabs-autohide",
            "tabs-visible",
            "tabs-wide",
            "toolbar-style",
            "titlebar-style",
        }) |key| {
            self.as(gobject.Object).notifyByPspec(
                @field(properties, key).impl.param_spec,
            );
        }

        // Remainder uses the config
        const config = if (priv.config) |v| v.get() else return;

        // Only add a solid background if we're opaque.
        self.toggleCssClass(
            "background",
            config.@"background-opacity" >= 1,
        );

        // Apply class to color headerbar if window-theme is set to `ghostty` and
        // GTK version is before 4.16. The conditional is because above 4.16
        // we use GTK CSS color variables.
        self.toggleCssClass(
            "window-theme-ghostty",
            !gtk_version.atLeast(4, 16, 0) and
                config.@"window-theme" == .ghostty,
        );

        // Move the tab bar to the proper location.
        priv.toolbar.remove(priv.tab_bar.as(gtk.Widget));
        switch (config.@"gtk-tabs-location") {
            .top => priv.toolbar.addTopBar(priv.tab_bar.as(gtk.Widget)),
            .bottom => priv.toolbar.addBottomBar(priv.tab_bar.as(gtk.Widget)),
        }

        // Do our window-protocol specific appearance sync.
        priv.winproto.syncAppearance() catch |err| {
            log.warn("failed to sync winproto appearance error={}", .{err});
        };
    }

    /// Sync the state of any actions on this window.
    fn syncActions(self: *Self) void {
        const has_selection = selection: {
            const surface = self.getActiveSurface() orelse
                break :selection false;
            const core_surface = surface.core() orelse
                break :selection false;
            break :selection core_surface.hasSelection();
        };

        const action_map: *gio.ActionMap = gobject.ext.cast(
            gio.ActionMap,
            self,
        ) orelse return;
        const action: *gio.SimpleAction = gobject.ext.cast(
            gio.SimpleAction,
            action_map.lookupAction("copy") orelse return,
        ) orelse return;
        action.setEnabled(@intFromBool(has_selection));
    }

    fn toggleCssClass(self: *Self, class: [:0]const u8, value: bool) void {
        const widget = self.as(gtk.Widget);
        if (value)
            widget.addCssClass(class.ptr)
        else
            widget.removeCssClass(class.ptr);
    }

    /// Perform a binding action on the window's active surface.
    fn performBindingAction(
        self: *Self,
        action: input.Binding.Action,
    ) void {
        const surface = self.getActiveSurface() orelse return;
        const core_surface = surface.core() orelse return;
        _ = core_surface.performBindingAction(action) catch |err| {
            log.warn("error performing binding action error={}", .{err});
            return;
        };
    }

    /// Queue a simple text-based toast. All text-based toasts share the
    /// same timeout for consistency.
    ///
    // This is not `pub` because we should be using signals emitted by
    // other widgets to trigger our toasts. Other objects should not
    // trigger toasts directly.
    fn addToast(self: *Self, title: [*:0]const u8) void {
        const toast = adw.Toast.new(title);
        toast.setTimeout(3);
        self.private().toast_overlay.addToast(toast);
    }

    fn connectSurfaceHandlers(
        self: *Self,
        tree: *const Surface.Tree,
    ) void {
        const priv = self.private();
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            // Before adding any new signal handlers, disconnect any that we may
            // have added before. Otherwise we may get multiple handlers for the
            // same signal.
            _ = gobject.signalHandlersDisconnectMatched(
                surface.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );

            _ = Surface.signals.@"present-request".connect(
                surface,
                *Self,
                surfacePresentRequest,
                self,
                .{},
            );
            _ = Surface.signals.@"clipboard-write".connect(
                surface,
                *Self,
                surfaceClipboardWrite,
                self,
                .{},
            );
            _ = Surface.signals.menu.connect(
                surface,
                *Self,
                surfaceMenu,
                self,
                .{},
            );
            _ = Surface.signals.@"toggle-fullscreen".connect(
                surface,
                *Self,
                surfaceToggleFullscreen,
                self,
                .{},
            );
            _ = Surface.signals.@"toggle-maximize".connect(
                surface,
                *Self,
                surfaceToggleMaximize,
                self,
                .{},
            );

            // If we've never had a surface initialize yet, then we register
            // this signal. Its theoretically possible to launch multiple surfaces
            // before init so we could register this on multiple and that is not
            // a problem because we'll check the flag again in each handler.
            if (!priv.surface_init) {
                _ = Surface.signals.init.connect(
                    surface,
                    *Self,
                    surfaceInit,
                    self,
                    .{},
                );
            }
        }
    }

    /// Disconnect all the surface handlers for the given tree. This should
    /// be called whenever a tree is no longer present in the window, e.g.
    /// when a tab is detached or the tree changes.
    fn disconnectSurfaceHandlers(
        self: *Self,
        tree: *const Surface.Tree,
    ) void {
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            _ = gobject.signalHandlersDisconnectMatched(
                surface.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );
        }
    }

    //---------------------------------------------------------------
    // Properties

    /// Whether this terminal is a quick terminal or not.
    pub fn isQuickTerminal(self: *Self) bool {
        return self.private().quick_terminal;
    }

    /// Get the currently active surface. See the "active-surface" property.
    /// This does not ref the value.
    pub fn getActiveSurface(self: *Self) ?*Surface {
        const tab = self.getSelectedTab() orelse return null;
        return tab.getActiveSurface();
    }

    /// Returns the configuration for this window. The reference count
    /// is not increased.
    pub fn getConfig(self: *Self) ?*Config {
        return self.private().config;
    }

    /// Get the tab view for this window. Returns the ACTIVE per-worktree view
    /// (the one currently visible in the worktree_stack), falling back to the
    /// template default view. All single-view tab operations route through
    /// here so they target the active worktree's tab space (#7).
    pub fn getTabView(self: *Self) *adw.TabView {
        return self.activeTabView();
    }

    /// The currently visible per-worktree TabView. Falls back to the template
    /// `tab_view` (default space) if the stack has no visible child yet.
    fn activeTabView(self: *Self) *adw.TabView {
        const priv = self.private();
        if (priv.worktree_stack.getVisibleChild()) |child| {
            if (gobject.ext.cast(adw.TabView, child)) |view| return view;
            // The stack should only ever hold TabViews; a non-TabView child
            // means a wiring bug elsewhere. Don't crash, but surface it.
            log.warn("worktree_stack visible child is not a TabView", .{});
        }
        return priv.tab_view;
    }

    /// The worktree path whose tab space is currently visible, or null when on
    /// the default (template) space. Used to pin the sidebar "Active" card to
    /// the focused worktree. Resolved by matching the visible stack child back
    /// to a registered per-worktree view.
    fn activeWorktreePath(self: *Self) ?[]const u8 {
        const priv = self.private();
        const active = priv.worktree_stack.getVisibleChild() orelse return null;
        var it = priv.worktree_views.iterator();
        while (it.next()) |entry| {
            const view = entry.value_ptr.*;
            if (view.as(gtk.Widget) == active) {
                const key = entry.key_ptr.*;
                // The default space is registered under the empty-string key.
                if (key.len == 0) return null;
                return key;
            }
        }
        return null;
    }

    /// Resolve the worktree path that owns `surface` (#22): the surface lives
    /// in a Tab, which lives in a per-worktree Adw.TabView registered in
    /// `worktree_views` keyed by path. Returns null for the default space
    /// (empty-string key) or when no owning view is found.
    fn worktreePathForSurface(self: *Self, surface: *Surface) ?[]const u8 {
        const priv = self.private();
        const view = ext.getAncestor(adw.TabView, surface.as(gtk.Widget)) orelse return null;
        var it = priv.worktree_views.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == view) {
                const key = entry.key_ptr.*;
                if (key.len == 0) return null; // default space
                return key;
            }
        }
        return null;
    }

    /// A stable worktree id for `SUPACODE_WORKTREE_ID`, derived from the
    /// surface's owning worktree path. Returns null for the default space
    /// (no worktree) or when the surface isn't yet in a worktree view. The
    /// returned slice is owned by the worktree_views map; callers must NOT
    /// free it and must copy it before the map mutates. (Named "id" for parity
    /// with the macOS env var; on Linux the worktree path IS the stable id and
    /// attribution is by the receiving surface, so it is not percent-encoded.)
    pub fn worktreeIdForSurface(self: *Self, surface: *Surface) ?[]const u8 {
        const path = self.worktreePathForSurface(surface) orelse return null;
        if (path.len == 0) return null;
        return path;
    }

    /// Whether worktree `path` has ≥1 running agent (#22). O(1) lookup into
    /// the incrementally-maintained `worktree_agents` map — never walks widget
    /// ancestry, so it's safe to call during teardown.
    fn worktreeHasAgent(self: *Self, path: []const u8) bool {
        return self.private().worktree_agents.contains(path);
    }

    /// A representative agent for worktree `path`'s Active card icon (#22), or
    /// null when the worktree has no agent.
    fn agentForWorktreePath(self: *Self, path: []const u8) ?agentpkg.Agent {
        const wa = self.private().worktree_agents.get(path) orelse return null;
        return wa.agent;
    }

    /// Increment the per-worktree agent count for `path` (#22), recording
    /// `agent` as the representative for the Active card icon. Owns a duped
    /// copy of `path` on first insert. Called when an agent attaches while the
    /// surface is live, so no ancestry walk is needed later.
    fn incrWorktreeAgent(self: *Self, path: []const u8, agent: agentpkg.Agent) void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        const gop = priv.worktree_agents.getOrPut(alloc, path) catch return;
        if (!gop.found_existing) {
            const key = alloc.dupe(u8, path) catch {
                _ = priv.worktree_agents.remove(path);
                return;
            };
            gop.key_ptr.* = key;
            gop.value_ptr.* = .{ .count = 1, .agent = agent };
        } else {
            gop.value_ptr.count += 1;
            gop.value_ptr.agent = agent;
        }
    }

    /// Decrement the per-worktree agent count for `path` (#22). Frees the
    /// owned key and drops the entry when the count reaches zero, so the
    /// worktree leaves "Active". When agents remain, re-elect a representative
    /// agent for the Active card icon from a still-attached surface so the
    /// card never keeps showing a just-detached agent's icon. (The detaching
    /// surface is already removed from `surface_agents` by the time this runs,
    /// so it can't re-elect itself.)
    fn decrWorktreeAgent(self: *Self, path: []const u8) void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        const entry = priv.worktree_agents.getEntry(path) orelse return;
        if (entry.value_ptr.count > 1) {
            entry.value_ptr.count -= 1;
            var it = priv.surface_agents.valueIterator();
            while (it.next()) |e| {
                if (e.path) |p| {
                    if (std.mem.eql(u8, p, path)) {
                        entry.value_ptr.agent = e.agent;
                        break;
                    }
                }
            }
            return;
        }
        const key = entry.key_ptr.*;
        _ = priv.worktree_agents.remove(path);
        alloc.free(key);
    }

    /// Update the title-bar identity chip (#10): avatar initials + branch
    /// (bold) over repo name, sourced from the active worktree. The chip is
    /// hidden when no specific worktree space is active (default/menu tabs).
    fn updateIdentityChip(self: *Self) void {
        const priv = self.private();

        const active_path = self.activeWorktreePath() orelse {
            priv.identity_chip.as(gtk.Widget).setVisible(@intFromBool(false));
            return;
        };

        // Resolve the active worktree's status row for branch/repo labels.
        var repo_name: []const u8 = "";
        var branch: []const u8 = "";
        for (priv.sidebar_statuses) |*st| {
            if (std.mem.eql(u8, st.path, active_path)) {
                repo_name = st.repo_name;
                branch = st.branch;
                break;
            }
        }
        if (repo_name.len == 0 and branch.len == 0) {
            priv.identity_chip.as(gtk.Widget).setVisible(@intFromBool(false));
            return;
        }

        const alloc = Application.default().allocator();
        if (alloc.dupeZ(u8, branch)) |z| {
            defer alloc.free(z);
            priv.identity_branch.setText(z.ptr);
        } else |_| {}
        if (alloc.dupeZ(u8, repo_name)) |z| {
            defer alloc.free(z);
            priv.identity_repo.setText(z.ptr);
            // Seed the avatar initials from the repo name.
            priv.identity_avatar.setText(z.ptr);
        } else |_| {}

        priv.identity_chip.as(gtk.Widget).setVisible(@intFromBool(true));
    }

    /// Find the TabView that owns `tab` (its nearest Adw.TabView ancestor),
    /// across all per-worktree views. Falls back to the active view.
    fn viewForTab(self: *Self, tab: *Tab) *adw.TabView {
        if (ext.getAncestor(adw.TabView, tab.as(gtk.Widget))) |view| return view;
        return self.activeTabView();
    }

    /// Total number of tab pages across every worktree view.
    fn totalTabPages(self: *Self) c_int {
        var total: c_int = 0;
        var vit = self.private().worktree_views.valueIterator();
        while (vit.next()) |view_ptr| total += view_ptr.*.getNPages();
        return total;
    }

    /// Connect the per-view signal handlers that the template wires for the
    /// default `tab_view`, so a runtime-created worktree view behaves
    /// identically. (overview create-tab / notify::open stay on the single
    /// tab_overview, which we repoint with setView on switch.)
    fn connectTabViewSignals(self: *Self, view: *adw.TabView) void {
        _ = gobject.signalConnectData(
            view.as(gobject.Object),
            "close-page",
            @ptrCast(&tabViewClosePage),
            self,
            null,
            .{},
        );
        _ = gobject.signalConnectData(
            view.as(gobject.Object),
            "page-attached",
            @ptrCast(&tabViewPageAttached),
            self,
            null,
            .{},
        );
        _ = gobject.signalConnectData(
            view.as(gobject.Object),
            "page-detached",
            @ptrCast(&tabViewPageDetached),
            self,
            null,
            .{},
        );
        _ = gobject.signalConnectData(
            view.as(gobject.Object),
            "create-window",
            @ptrCast(&tabViewCreateWindow),
            self,
            null,
            .{},
        );
        _ = gobject.signalConnectData(
            view.as(gobject.Object),
            "setup-menu",
            @ptrCast(&setupTabMenu),
            self,
            null,
            .{},
        );
        _ = gobject.Object.signals.notify.connect(
            view,
            *Self,
            tabViewNPages,
            self,
            .{ .detail = "n-pages" },
        );
        _ = gobject.Object.signals.notify.connect(
            view,
            *Self,
            tabViewSelectedPage,
            self,
            .{ .detail = "selected-page" },
        );
    }

    /// Register the template `tab_view` as the default-space view under the
    /// empty-string key. Called once at construction.
    fn registerDefaultWorktreeView(self: *Self) void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        const key = alloc.dupe(u8, "") catch return;
        priv.worktree_views.put(alloc, key, priv.tab_view) catch {
            alloc.free(key);
            return;
        };
    }

    /// Ensure a TabView exists for `path`, creating and wiring one if needed.
    /// Returns the view (or the default view on allocation failure).
    fn ensureWorktreeView(self: *Self, path: []const u8) *adw.TabView {
        const priv = self.private();
        const alloc = Application.default().allocator();

        if (priv.worktree_views.get(path)) |view| return view;

        // Reserve the map slot BEFORE creating/adding the view so a partially
        // registered (orphan) view can never end up in the stack but missing
        // from worktree_views on OOM (review: ensureWorktreeView orphan). On
        // allocation failure we fall back to the default view untouched.
        const key = alloc.dupe(u8, path) catch return priv.tab_view;
        const gop = priv.worktree_views.getOrPut(alloc, key) catch {
            alloc.free(key);
            return priv.tab_view;
        };
        // getOrPut on a fresh key can't already exist (we checked .get above),
        // but guard anyway to avoid leaking the dup.
        if (gop.found_existing) {
            alloc.free(key);
            return gop.value_ptr.*;
        }
        // Initialize the slot to a safe sentinel before we create the real
        // view, so the map never exposes an uninitialized value_ptr.
        gop.value_ptr.* = priv.tab_view;

        const view = gobject.ext.newInstance(adw.TabView, .{});
        view.as(gtk.Widget).setVisible(@intFromBool(true));
        self.connectTabViewSignals(view);
        _ = priv.worktree_stack.addChild(view.as(gtk.Widget));
        gop.value_ptr.* = view;
        return view;
    }

    /// Make `view` the active tab space: show it in the stack and repoint the
    /// shared tab bar + overview at it.
    fn switchToWorktreeView(self: *Self, view: *adw.TabView) void {
        const priv = self.private();
        priv.worktree_stack.setVisibleChild(view.as(gtk.Widget));
        priv.tab_bar.setView(view);
        priv.tab_overview.setView(view);
        // Recompute window-level state (title/subtitle) for the newly active
        // view by re-running the selected-page sync against it.
        self.refreshActiveTabBinding();
        // Re-pin the sidebar "Active" card to the newly focused worktree (#9).
        self.rebuildSidebarRows();
        // Update the title-bar identity chip for the newly focused worktree (#10).
        self.updateIdentityChip();
    }

    /// Sync the tab binding group (title/subtitle/etc.) from the active view's
    /// selected page. Shared by the selected-page signal and view switching.
    fn refreshActiveTabBinding(self: *Self) void {
        const priv = self.private();
        priv.tab_bindings.setSource(null);
        const view = self.activeTabView();
        const page = view.getSelectedPage() orelse return;
        const child = page.getChild();
        assert(gobject.ext.isA(child, Tab));
        priv.tab_bindings.setSource(child.as(gobject.Object));
        page.setNeedsAttention(@intFromBool(false));
    }
    /// Get the current window decoration value for this window.
    pub fn getWindowDecoration(self: *Self) configpkg.WindowDecoration {
        const priv = self.private();
        if (priv.window_decoration) |v| return v;
        if (priv.config) |v| return v.get().@"window-decoration";
        return .auto;
    }

    /// Toggle the window decorations for this window.
    pub fn toggleWindowDecorations(self: *Self) void {
        const priv = self.private();

        if (priv.window_decoration) |_| {
            // Unset any previously set window decoration settings
            self.setWindowDecoration(null);
            return;
        }

        const config = if (priv.config) |v| v.get() else return;
        self.setWindowDecoration(switch (config.@"window-decoration") {
            // Use auto when the decoration is initially none
            .none => .auto,

            // Anything non-none to none
            .auto, .client, .server => .none,
        });
    }

    /// Set the window decoration override for this window. If this is null,
    /// then we'll revert back to the configuration's default.
    fn setWindowDecoration(
        self: *Self,
        new_: ?configpkg.WindowDecoration,
    ) void {
        const priv = self.private();
        priv.window_decoration = new_;
        self.syncAppearance();
    }

    /// Get the currently selected tab as a Tab object.
    fn getSelectedTab(self: *Self) ?*Tab {
        const page = self.activeTabView().getSelectedPage() orelse return null;
        const child = page.getChild();
        assert(gobject.ext.isA(child, Tab));
        return gobject.ext.cast(Tab, child);
    }

    /// Returns true if this window needs confirmation before quitting. Checks
    /// every worktree tab space (#7), not just the active one.
    fn getNeedsConfirmQuit(self: *Self) bool {
        var vit = self.private().worktree_views.valueIterator();
        while (vit.next()) |view_ptr| {
            const view = view_ptr.*;
            const n = view.getNPages();
            for (0..@intCast(n)) |i| {
                const page = view.getNthPage(@intCast(i));
                const child = page.getChild();
                const tab = gobject.ext.cast(Tab, child) orelse {
                    log.warn("unexpected non-Tab child in tab view", .{});
                    continue;
                };
                if (tab.getNeedsConfirmQuit()) return true;
            }
        }
        return false;
    }

    fn isFullscreen(self: *Window) bool {
        return self.as(gtk.Window).isFullscreen() != 0;
    }

    fn isMaximized(self: *Window) bool {
        return self.as(gtk.Window).isMaximized() != 0;
    }

    fn getHeaderbarVisible(self: *Self) bool {
        const priv = self.private();

        // Never display the header bar when CSDs are disabled.
        const csd_enabled = priv.winproto.clientSideDecorationEnabled();
        if (!csd_enabled) return false;

        // Never display the header bar as a quick terminal.
        if (priv.quick_terminal) return false;

        // If we're fullscreen we never show the header bar.
        if (self.isFullscreen()) return false;

        // The remainder needs a config
        const config_obj = self.private().config orelse return true;
        const config = config_obj.get();

        // *Conditionally* disable the header bar when maximized, and
        // gtk-titlebar-hide-when-maximized is set
        if (self.isMaximized() and config.@"gtk-titlebar-hide-when-maximized") {
            return false;
        }

        return switch (config.@"gtk-titlebar-style") {
            // If the titlebar style is tabs never show the titlebar.
            .tabs => false,

            // If the titlebar style is native show the titlebar if configured
            // to do so.
            .native => config.@"gtk-titlebar",
        };
    }

    fn getTabsAutohide(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;

        return switch (config.@"gtk-titlebar-style") {
            // If the titlebar style is tabs we cannot autohide.
            .tabs => false,

            .native => switch (config.@"window-show-tab-bar") {
                // Auto we always autohide... obviously.
                .auto => true,

                // Always we never autohide because we always show the tab bar.
                .always => false,

                // Never we autohide because it doesn't actually matter,
                // since getTabsVisible will return false.
                .never => true,
            },
        };
    }

    fn getTabsVisible(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;

        switch (config.@"gtk-titlebar-style") {
            .tabs => {
                // *Conditionally* disable the tab bar when maximized, the titlebar
                // style is tabs, and gtk-titlebar-hide-when-maximized is set.
                if (self.isMaximized() and config.@"gtk-titlebar-hide-when-maximized") return false;

                // If the titlebar style is tabs the tab bar must always be visible.
                return true;
            },
            .native => {
                return switch (config.@"window-show-tab-bar") {
                    .always, .auto => true,
                    .never => false,
                };
            },
        }
    }

    fn getTabsWide(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;
        return config.@"gtk-wide-tabs";
    }

    fn getToolbarStyle(self: *Self) adw.ToolbarStyle {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return .raised;
        return switch (config.@"gtk-toolbar-style") {
            .flat => .flat,
            .raised => .raised,
            .@"raised-border" => .raised_border,
        };
    }

    fn getTitlebarStyle(self: *Self) TitlebarStyle {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return .native;
        return config.@"gtk-titlebar-style";
    }

    fn propConfig(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.config) |config_obj| {
            const config = config_obj.get();
            if (config.@"app-notifications".@"config-reload") {
                self.addToast(i18n._("Reloaded the configuration"));
            }
        }

        self.syncAppearance();
    }

    fn propIsActive(
        _: *gtk.Window,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // Hide quick-terminal if set to autohide
        if (self.isQuickTerminal()) {
            if (self.getConfig()) |cfg| {
                if (cfg.get().@"quick-terminal-autohide" and self.as(gtk.Window).isActive() == 0) {
                    self.toggleVisibility();
                }
            }
        }

        // Don't change urgency if we're not the active window.
        if (self.as(gtk.Window).isActive() == 0) return;

        self.winproto().setUrgent(false) catch |err| {
            log.warn(
                "winproto failed to reset urgency={}",
                .{err},
            );
        };
    }

    fn propGdkSurfaceDims(
        _: *gdk.Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // X11 needs to fix blurring on resize, but winproto implementations
        // could do anything.
        self.private().winproto.resizeEvent() catch |err| {
            log.warn(
                "winproto resize event failed error={}",
                .{err},
            );
        };
    }

    fn propFullscreened(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncAppearance();
    }

    fn propMaximized(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncAppearance();
    }

    fn propMenuActive(
        button: *gtk.MenuButton,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // Debian 12 is stuck on GTK 4.8
        if (!gtk_version.atLeast(4, 10, 0)) return;

        // We only care if we're activating. If we're activating then
        // we need to check the validity of our menu items.
        const active = button.getActive() != 0;
        if (!active) return;

        self.syncActions();
    }

    fn propQuickTerminal(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.surface_init) {
            log.warn("quick terminal property can't be changed after surfaces have been initialized", .{});
            return;
        }

        if (priv.quick_terminal) {
            // Initialize the quick terminal at the app-layer
            Application.default().winproto().initQuickTerminal(self) catch |err| {
                log.warn("failed to initialize quick terminal error={}", .{err});
                return;
            };
        }
    }

    fn propScaleFactor(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // On some platforms (namely X11) we need to refresh our appearance when
        // the scale factor changes. In theory this could be more fine-grained as
        // a full refresh could be expensive, but a) this *should* be rare, and
        // b) quite noticeable visual bugs would occur if this is not present.
        self.private().winproto.syncAppearance() catch |err| {
            log.warn(
                "failed to sync appearance after scale factor has been updated={}",
                .{err},
            );
            return;
        };
    }

    fn closureTitlebarStyleIsTab(
        _: *Self,
        value: TitlebarStyle,
    ) callconv(.c) c_int {
        return @intFromBool(switch (value) {
            .native => false,
            .tabs => true,
        });
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        // Mark teardown in progress so per-view notify::n-pages handlers don't
        // re-enter window-close logic as the stack disposes its children.
        priv.disposing = true;

        priv.command_palette.set(null);

        // Supacode sidebar teardown: stop the poll timer and free owned state.
        const alloc = Application.default().allocator();
        if (priv.sidebar_timer) |timer| {
            _ = glib.Source.remove(timer);
            priv.sidebar_timer = null;
        }
        if (priv.liveness_timer) |timer| {
            _ = glib.Source.remove(timer);
            priv.liveness_timer = null;
        }
        if (priv.sidebar_statuses.len > 0) {
            sidebar.freeStatuses(alloc, priv.sidebar_statuses);
            priv.sidebar_statuses = &.{};
        }
        priv.sidebar_store.deinit(alloc);
        {
            var it = priv.sidebar_attention.valueIterator();
            while (it.next()) |v| alloc.free(v.*);
            priv.sidebar_attention.deinit(alloc);
            priv.sidebar_attention = .empty;
        }
        {
            var it = priv.sidebar_collapsed.keyIterator();
            while (it.next()) |k| alloc.free(k.*);
            priv.sidebar_collapsed.deinit(alloc);
            priv.sidebar_collapsed = .empty;
        }
        priv.sidebar_rows.deinit(alloc);
        priv.sidebar_rows = .empty;
        {
            // Free cached worktree paths on each agent entry, then the map.
            var it = priv.surface_agents.valueIterator();
            while (it.next()) |e| {
                if (e.path) |p| alloc.free(p);
            }
            priv.surface_agents.deinit(alloc);
            priv.surface_agents = .empty;
        }
        {
            // Free owned worktree-agent count keys (#22).
            var it = priv.worktree_agents.keyIterator();
            while (it.next()) |k| alloc.free(k.*);
            priv.worktree_agents.deinit(alloc);
            priv.worktree_agents = .empty;
        }

        // Supacode (#11): free notification history.
        for (priv.notifications.items) |*n| n.deinit(alloc);
        priv.notifications.deinit(alloc);
        priv.notifications = .empty;

        // Supacode per-worktree views (#7): free the owned (duped) path keys.
        // The TabView widgets themselves are owned by the worktree_stack and
        // torn down by disposeTemplate / GTK.
        {
            var it = priv.worktree_views.keyIterator();
            while (it.next()) |k| alloc.free(k.*);
            priv.worktree_views.deinit(alloc);
            priv.worktree_views = .empty;
        }

        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }

        priv.tab_bindings.setSource(null);

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.tab_bindings.unref();
        priv.winproto.deinit();

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal handlers

    fn windowRealize(_: *gtk.Widget, self: *Window) callconv(.c) void {
        const app = Application.default();

        // Initialize our window protocol logic
        if (winprotopkg.Window.init(
            app.allocator(),
            app.winproto(),
            self,
        )) |wp| {
            self.private().winproto = wp;
        } else |err| {
            log.warn("failed to initialize window protocol error={}", .{err});
            return;
        }

        // We need to setup resize notifications on our surface,
        // which is only available after the window had been realized.
        if (self.as(gtk.Native).getSurface()) |gdk_surface| {
            _ = gobject.Object.signals.notify.connect(
                gdk_surface,
                *Self,
                propGdkSurfaceDims,
                self,
                .{ .detail = "width" },
            );
            _ = gobject.Object.signals.notify.connect(
                gdk_surface,
                *Self,
                propGdkSurfaceDims,
                self,
                .{ .detail = "height" },
            );
        }

        // When we are realized we always setup our appearance since this
        // calls some winproto functions.
        self.syncAppearance();

        // Set up the Supacode worktree sidebar: connect row activation,
        // perform the first scan, and start the periodic refresh poll.
        self.initSidebar();

        // Initialize the notification bell popover empty-state (#11).
        self.refreshNotifications();
    }

    /// Connect the sidebar ListBox signals, run the first scan, and start the
    /// 5s refresh timer. Safe to call once after the window is realized.
    fn initSidebar(self: *Window) void {
        const priv = self.private();

        // Load the user-curated project roots (#21). Empty on first run — the
        // sidebar starts empty and the user adds folders via the `+` button.
        priv.sidebar_store = sidebar_store.load(Application.default().allocator());

        _ = gtk.ListBox.signals.row_activated.connect(
            priv.sidebar_list,
            *Window,
            sidebarRowActivated,
            self,
            .{},
        );

        // First scan immediately, then poll.
        self.refreshSidebar();
        priv.sidebar_timer = glib.timeoutAdd(5000, sidebarPollTimer, self);

        // Start the agent-presence liveness sweep (AgentPresenceFeature
        // livenessSweepInterval = 2s). Reaps presence whose local pid is dead.
        priv.liveness_timer = glib.timeoutAdd(2000, livenessSweepTimer, self);
    }

    fn livenessSweepTimer(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Window = @ptrCast(@alignCast(ud orelse return 0));
        self.livenessSweep();
        return @intFromBool(true);
    }

    /// Reap agent presence whose attributed local pid is dead. Mirrors
    /// AgentPresenceFeature.liveness: a non-null pid that fails `kill(pid, 0)`
    /// (process gone) means a crashed local agent that never sent session_end,
    /// so its surface presence is cleared. Pid-less records (SSH attach) are
    /// skipped — they have no local pid to check and are torn down by
    /// session_end or surface close. Rebuilds the sidebar only if something
    /// changed.
    fn livenessSweep(self: *Window) void {
        const priv = self.private();
        var dead: std.ArrayListUnmanaged(*Surface) = .empty;
        defer dead.deinit(Application.default().allocator());

        var it = priv.surface_agents.iterator();
        while (it.next()) |entry| {
            const pid = entry.value_ptr.pid orelse continue;
            // kill(pid, 0): 0 -> alive; ESRCH -> dead. Reject non-positive pids
            // (kill(0/-N, 0) targets process groups, mirroring the macOS guard).
            if (pid <= 0) continue;
            std.posix.kill(pid, 0) catch |err| switch (err) {
                error.ProcessNotFound => dead.append(
                    Application.default().allocator(),
                    entry.key_ptr.*,
                ) catch {},
                // EPERM etc.: process exists but we can't signal it — treat as alive.
                else => {},
            };
        }

        if (dead.items.len == 0) return;
        for (dead.items) |surface| {
            _ = self.removeSurfaceAgent(surface);
            self.refreshTabAgentIcon(surface);
        }
        self.rebuildSidebarRows();
    }

    fn sidebarPollTimer(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Window = @ptrCast(@alignCast(ud orelse return 0));
        self.refreshSidebar();
        // Return true to keep the timer firing.
        return @intFromBool(true);
    }

    /// Resolve the projects root (default: $HOME/git). Retained for the
    /// identity chip / fallbacks; the sidebar itself scans the user-curated
    /// store (#21), not this root.
    fn projectsRoot(alloc: std.mem.Allocator) ?[]u8 {
        const home = std.posix.getenv("HOME") orelse return null;
        return std.fs.path.join(alloc, &.{ home, "git" }) catch null;
    }

    /// Rescan the user-curated project roots and rebuild the sidebar rows.
    /// Issue #21: scans ONLY the persisted roots in `sidebar_store`, never a
    /// blanket `~/git` walk. An empty store yields an empty sidebar.
    fn refreshSidebar(self: *Window) void {
        const priv = self.private();
        const alloc = Application.default().allocator();

        const statuses = sidebar.scanPaths(alloc, priv.sidebar_store.roots.items) catch |err| {
            log.warn("sidebar: scan failed err={}", .{err});
            return;
        };

        // Replace stored statuses (free the previous scan).
        if (priv.sidebar_statuses.len > 0) {
            sidebar.freeStatuses(alloc, priv.sidebar_statuses);
        }
        priv.sidebar_statuses = statuses;

        self.rebuildSidebarRows();
        // Refresh the identity chip now that branch/repo labels are available (#10).
        self.updateIdentityChip();
    }

    /// Handler for the sidebar header `+` button: present a folder picker and,
    /// on selection, add the chosen path to the persisted store and rescan.
    fn sidebarAddClicked(_: *gtk.Button, self: *Window) callconv(.c) void {
        const dialog = gtk.FileDialog.new();
        // The dialog holds its own ref while presented; release ours after.
        defer dialog.unref();
        dialog.setTitle("Add Folder");
        dialog.setModal(@intFromBool(true));

        // Keep the window alive across the async callback.
        _ = self.ref();
        const root = self.as(gtk.Widget).getRoot();
        const parent: ?*gtk.Window = if (root) |r|
            gobject.ext.cast(gtk.Window, r)
        else
            null;
        dialog.selectFolder(parent, null, sidebarAddFolderFinish, self);
    }

    fn sidebarAddFolderFinish(
        source: ?*gobject.Object,
        res: *gio.AsyncResult,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(ud orelse return));
        defer self.unref();
        const dialog = gobject.ext.cast(gtk.FileDialog, source orelse return) orelse return;

        var gerr: ?*glib.Error = null;
        const file = dialog.selectFolderFinish(res, &gerr) orelse {
            if (gerr) |err| {
                defer err.free();
                // DISMISSED (user cancelled) is expected and not worth a warning.
                log.debug("sidebar: folder picker closed: {s}", .{err.f_message orelse "(dismissed)"});
            }
            return;
        };
        defer file.unref();

        const cpath = file.getPath() orelse return;
        defer glib.free(cpath);
        const raw_path = std.mem.sliceTo(cpath, 0);

        const alloc = Application.default().allocator();
        const priv = self.private();

        // Canonicalize so the stored entry matches git's `--show-toplevel`
        // (which is realpath'd): this keeps the per-repo remove (✕) button's
        // `contains()` check true for symlinked / trailing-slash picks. Fall
        // back to the raw path if realpath fails (e.g. permissions).
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fs.cwd().realpath(raw_path, &path_buf) catch raw_path;

        const added = priv.sidebar_store.add(alloc, path) catch |err| {
            log.warn("sidebar: cannot add root {s}: {}", .{ path, err });
            return;
        };
        if (!added) return; // already present

        sidebar_store.save(alloc, &priv.sidebar_store) catch |err| {
            log.warn("sidebar: cannot persist after add: {}", .{err});
        };
        self.refreshSidebar();
    }

    /// Remove a project root from the sidebar store and rescan. Used by the
    /// repo-header remove (✕) button, which only appears for repos whose root
    /// is an exact store entry (#21 removal). An exact match is therefore the
    /// only case we need to handle.
    fn removeSidebarRoot(self: *Window, repo_root: []const u8) void {
        const alloc = Application.default().allocator();
        const priv = self.private();

        if (!priv.sidebar_store.remove(alloc, repo_root)) return;

        sidebar_store.save(alloc, &priv.sidebar_store) catch |err| {
            log.warn("sidebar: cannot persist after remove: {}", .{err});
        };
        self.refreshSidebar();
    }

    /// Rebuild the ListBox rows from `sidebar_statuses`, grouping worktrees
    /// under collapsible repo headers. Also rebuilds the `sidebar_rows`
    /// index->ref mapping used by row activation. Safe to call any time the
    /// statuses, attention set, or collapsed set changes.
    fn rebuildSidebarRows(self: *Window) void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        const statuses = priv.sidebar_statuses;

        priv.sidebar_rows.clearRetainingCapacity();
        priv.sidebar_list.removeAll();

        // Supacode: pinned "Active" section at the very top. Per #22 this
        // lists EVERY worktree that has ≥1 running agent (each as its own
        // card), not just the focused one (#9). The focused worktree is also
        // included even with no agent so the user always sees where they are.
        // The set comes from the incrementally-maintained `worktree_agents`
        // count via `worktreeHasAgent` — an O(1) lookup that never walks widget
        // ancestry, so it's safe during teardown.
        {
            const active_path = self.activeWorktreePath();
            var shown_header = false;
            for (statuses, 0..) |*st, idx| {
                const is_focused = if (active_path) |ap| std.mem.eql(u8, st.path, ap) else false;
                if (!is_focused and !self.worktreeHasAgent(st.path)) continue;

                if (!shown_header) {
                    const hdr = buildActiveHeaderRow();
                    priv.sidebar_list.append(hdr.as(gtk.Widget));
                    priv.sidebar_rows.append(alloc, .{ .kind = .active_header, .index = idx }) catch {};
                    shown_header = true;
                }

                const card = self.buildActiveCardRow(st);
                priv.sidebar_list.append(card.as(gtk.Widget));
                priv.sidebar_rows.append(alloc, .{ .kind = .active_card, .index = idx }) catch {};
            }
        }

        var i: usize = 0;
        while (i < statuses.len) {
            // Find the contiguous run of worktrees belonging to this repo.
            const repo_root = statuses[i].repo_root;
            var j = i;
            while (j < statuses.len and std.mem.eql(u8, statuses[j].repo_root, repo_root)) : (j += 1) {}
            const group = statuses[i..j];

            const collapsed = priv.sidebar_collapsed.contains(repo_root);

            // Repo header row.
            const header = self.buildRepoHeaderRow(group, collapsed);
            priv.sidebar_list.append(header.as(gtk.Widget));
            priv.sidebar_rows.append(alloc, .{ .kind = .repo_header, .index = i }) catch {};

            // Worktree leaf rows (hidden when collapsed).
            if (!collapsed) {
                for (group, i..) |*st, idx| {
                    const row = self.buildWorktreeRow(st);
                    priv.sidebar_list.append(row.as(gtk.Widget));
                    priv.sidebar_rows.append(alloc, .{ .kind = .worktree, .index = idx }) catch {};
                }
            }

            i = j;
        }
    }

    /// Build the "Active" section header row: small muted caps label with a
    /// blue presence dot, matching macOS annotation #2.
    fn buildActiveHeaderRow() *gtk.ListBoxRow {
        const row = gtk.ListBoxRow.new();
        row.setSelectable(@intFromBool(false));
        row.setActivatable(@intFromBool(false));

        const box = gtk.Box.new(.horizontal, 6);
        box.as(gtk.Widget).setMarginStart(10);
        box.as(gtk.Widget).setMarginEnd(8);
        box.as(gtk.Widget).setMarginTop(6);
        box.as(gtk.Widget).setMarginBottom(2);

        const label = gtk.Label.new(null);
        label.setMarkup("<small><span foreground='#888'>ACTIVE</span></small> <span foreground='#61afef'>\u{25CF}</span>");
        label.setXalign(0);
        box.append(label.as(gtk.Widget));

        row.setChild(box.as(gtk.Widget));
        return row;
    }

    /// Build the pinned "Active" session card: branch icon + branch name, a
    /// repo · worktree subtitle, and the active agent icon pinned top-right.
    fn buildActiveCardRow(self: *Window, st: *const sidebar.WorktreeStatus) *gtk.ListBoxRow {
        const alloc = Application.default().allocator();
        const row = gtk.ListBoxRow.new();
        // Distinct highlight so the card reads as selected, macOS-style.
        row.as(gtk.Widget).addCssClass("sidebar-active-card");

        const box = gtk.Box.new(.horizontal, 8);
        box.as(gtk.Widget).setMarginStart(10);
        box.as(gtk.Widget).setMarginEnd(8);
        box.as(gtk.Widget).setMarginTop(4);
        box.as(gtk.Widget).setMarginBottom(6);

        const branch_z = alloc.dupeZ(u8, st.branch) catch return row;
        defer alloc.free(branch_z);
        const branch_esc = glib.markupEscapeText(branch_z.ptr, -1);
        defer glib.free(branch_esc);
        const repo_z = alloc.dupeZ(u8, st.repo_name) catch return row;
        defer alloc.free(repo_z);
        const repo_esc = glib.markupEscapeText(repo_z.ptr, -1);
        defer glib.free(repo_esc);

        // Two-line text block (left, expanding): branch (bold) then a muted
        // "repo · worktree" subtitle.
        const text_box = gtk.Box.new(.vertical, 1);
        text_box.as(gtk.Widget).setHexpand(@intFromBool(true));

        const title_markup = std.fmt.allocPrintSentinel(
            alloc,
            "<span foreground='#888'>\u{2387}</span> <b><span foreground='#eee'>{s}</span></b>",
            .{branch_esc},
            0,
        ) catch return row;
        defer alloc.free(title_markup);
        const title = gtk.Label.new(null);
        title.setMarkup(title_markup.ptr);
        title.setXalign(0);
        title.setEllipsize(.end);
        text_box.append(title.as(gtk.Widget));

        const subtitle_markup = std.fmt.allocPrintSentinel(
            alloc,
            "<small><span foreground='#999'>{s}</span> <span foreground='#666'>\u{00B7}</span> <span foreground='#e5c07b'>Default</span></small>",
            .{repo_esc},
            0,
        ) catch return row;
        defer alloc.free(subtitle_markup);
        const subtitle = gtk.Label.new(null);
        subtitle.setMarkup(subtitle_markup.ptr);
        subtitle.setXalign(0);
        subtitle.setEllipsize(.end);
        text_box.append(subtitle.as(gtk.Widget));

        box.append(text_box.as(gtk.Widget));

        // Agent icon (right): this worktree's own agent, if any (#22). Keyed
        // by the card's worktree path so each Active card shows its own agent,
        // not just the focused surface's.
        if (self.agentForWorktreePath(st.path)) |agent| {
            if (agent.newIcon()) |icon| {
                defer icon.unref();
                const img = gtk.Image.newFromGicon(icon);
                img.as(gtk.Widget).setValign(.start);
                img.as(gtk.Widget).setTooltipText(agent.label().ptr);
                box.append(img.as(gtk.Widget));
            }
        }

        row.setChild(box.as(gtk.Widget));
        return row;
    }

    /// Build a collapsible repo header row. Aggregates the group's diff state
    /// and shows a disclosure triangle + repo name + summary badges.
    fn buildRepoHeaderRow(
        self: *Window,
        group: []const sidebar.WorktreeStatus,
        collapsed: bool,
    ) *gtk.ListBoxRow {
        const alloc = Application.default().allocator();
        const row = gtk.ListBoxRow.new();

        const box = gtk.Box.new(.horizontal, 6);
        box.as(gtk.Widget).setMarginStart(6);
        box.as(gtk.Widget).setMarginEnd(8);
        box.as(gtk.Widget).setMarginTop(5);
        box.as(gtk.Widget).setMarginBottom(5);

        const repo_name = if (group.len > 0) group[0].repo_name else "";
        const repo_branch = if (group.len > 0) group[0].branch else "";

        // Aggregate diff counts across the group's worktrees.
        var added: u32 = 0;
        var removed: u32 = 0;
        var any_attention = false;
        for (group) |*st| {
            added +|= st.added;
            removed +|= st.removed;
            if (self.pathHasAttention(st.path)) any_attention = true;
        }

        const arrow: []const u8 = if (collapsed) "\u{25B8}" else "\u{25BE}";

        const name_z = alloc.dupeZ(u8, repo_name) catch return row;
        defer alloc.free(name_z);
        const name_esc = glib.markupEscapeText(name_z.ptr, -1);
        defer glib.free(name_esc);
        const branch_z = alloc.dupeZ(u8, repo_branch) catch return row;
        defer alloc.free(branch_z);
        const branch_esc = glib.markupEscapeText(branch_z.ptr, -1);
        defer glib.free(branch_esc);

        // Name label (left): arrow + repo name (+ branch when single worktree).
        // Ellipsizes and expands so the title takes the squeeze, macOS-style.
        const markup = if (group.len == 1)
            std.fmt.allocPrintSentinel(
                alloc,
                "<span foreground='#888'>{s}</span> <b>{s}</b> <small><span foreground='#888'>{s}</span></small>",
                .{ arrow, name_esc, branch_esc },
                0,
            ) catch return row
        else
            std.fmt.allocPrintSentinel(
                alloc,
                "<span foreground='#888'>{s}</span> <b>{s}</b>",
                .{ arrow, name_esc },
                0,
            ) catch return row;
        defer alloc.free(markup);

        const label = gtk.Label.new(null);
        label.setMarkup(markup.ptr);
        label.setXalign(0);
        label.as(gtk.Widget).setHexpand(@intFromBool(true));
        label.setEllipsize(.end);
        box.append(label.as(gtk.Widget));

        // Badge label (right): aggregated diff stat + attention bell. Fixed
        // size, right-aligned, so counters never get clipped by long names.
        var badge_buf: [320]u8 = undefined;
        const badges: []const u8 = blk: {
            var stream = std.io.fixedBufferStream(&badge_buf);
            const w = stream.writer();
            // macOS shows both +added and -removed together whenever any
            // change exists (so "+8 -0" renders), not only the non-zero side.
            if (added > 0 or removed > 0) {
                w.print("<small><span foreground='#98c379'>+{d}</span> <span foreground='#e06c75'>-{d}</span></small>", .{ added, removed }) catch {};
            }
            if (any_attention) w.print(" <span foreground='#e06c75'>\u{1F514}</span>", .{}) catch {};
            break :blk std.mem.trim(u8, stream.getWritten(), " ");
        };
        if (badges.len > 0) {
            const badge_z = alloc.dupeZ(u8, badges) catch return row;
            defer alloc.free(badge_z);
            const badge_label = gtk.Label.new(null);
            badge_label.setMarkup(badge_z.ptr);
            badge_label.setXalign(1);
            box.append(badge_label.as(gtk.Widget));
        }

        // Remove (✕) button (#21): drops this repo's folder from the curated
        // sidebar store. Only shown when this repo's root is itself an exact
        // store entry — repos discovered via a parent folder (e.g. a `~/git`
        // root) are not individually removable, so clicking ✕ can never
        // silently drop a whole parent folder of sibling repos. The repo_root
        // is attached as glib-owned data so the handler knows which root to
        // remove without index bookkeeping.
        const repo_root_str = if (group.len > 0) group[0].repo_root else "";
        if (repo_root_str.len > 0 and self.private().sidebar_store.contains(repo_root_str)) {
            const remove_btn = gtk.Button.new();
            remove_btn.setIconName("window-close-symbolic");
            remove_btn.as(gtk.Widget).addCssClass("flat");
            remove_btn.as(gtk.Widget).setValign(.center);
            remove_btn.as(gtk.Widget).setTooltipText("Remove Folder");
            const root_z = alloc.dupeZ(u8, repo_root_str) catch return row;
            defer alloc.free(root_z);
            remove_btn.as(gobject.Object).setDataFull(
                "supacode-repo-root",
                glib.strdup(root_z.ptr),
                glibFreeData,
            );
            _ = gtk.Button.signals.clicked.connect(
                remove_btn,
                *Window,
                sidebarRemoveClicked,
                self,
                .{},
            );
            box.append(remove_btn.as(gtk.Widget));
        }

        row.setChild(box.as(gtk.Widget));
        return row;
    }

    /// GDestroyNotify that frees a glib-allocated blob attached via setDataFull.
    fn glibFreeData(ptr: ?*anyopaque) callconv(.c) void {
        if (ptr) |p| glib.free(p);
    }

    /// Click handler for a repo header's remove (✕) button. Dupes the path
    /// before calling `removeSidebarRoot`, because that rebuilds the sidebar
    /// (destroying this button and the glib-owned data behind `cstr`).
    fn sidebarRemoveClicked(btn: *gtk.Button, self: *Window) callconv(.c) void {
        const data = btn.as(gobject.Object).getData("supacode-repo-root") orelse return;
        const cstr: [*:0]const u8 = @ptrCast(data);
        const alloc = Application.default().allocator();
        const path = alloc.dupe(u8, std.mem.sliceTo(cstr, 0)) catch return;
        defer alloc.free(path);
        self.removeSidebarRoot(path);
    }

    /// Build one ListBoxRow widget for a worktree status (leaf under a repo).
    fn buildWorktreeRow(self: *Window, st: *const sidebar.WorktreeStatus) *gtk.ListBoxRow {
        const alloc = Application.default().allocator();

        const row = gtk.ListBoxRow.new();

        const box = gtk.Box.new(.horizontal, 6);
        box.as(gtk.Widget).setMarginStart(22);
        box.as(gtk.Widget).setMarginEnd(8);
        box.as(gtk.Widget).setMarginTop(3);
        box.as(gtk.Widget).setMarginBottom(3);

        // Status dot color: pushable=yellow, dirty=orange, behind=blue, clean=green.
        const dot_color: []const u8 = if (st.pushable())
            "#e5c07b"
        else if (st.dirty)
            "#d19a66"
        else if (st.behind > 0)
            "#61afef"
        else
            "#98c379";

        const branch_z = alloc.dupeZ(u8, st.branch) catch return row;
        defer alloc.free(branch_z);
        const branch_esc = glib.markupEscapeText(branch_z.ptr, -1);
        defer glib.free(branch_esc);

        // Badges: up-ahead down-behind / no upstream, plus +adds/-dels diff
        // counts. The diff stat shows both sides together (macOS "+8 -0")
        // whenever the worktree has any uncommitted change.
        var badge_buf: [512]u8 = undefined;
        const badges: []const u8 = blk: {
            var stream = std.io.fixedBufferStream(&badge_buf);
            const w = stream.writer();
            if (st.no_upstream) {
                w.print("<small><span foreground='#777'>no upstream</span></small>", .{}) catch {};
            } else {
                if (st.ahead > 0) w.print("<small><span foreground='#e5c07b'>\u{2191}{d}</span></small> ", .{st.ahead}) catch {};
                if (st.behind > 0) w.print("<small><span foreground='#61afef'>\u{2193}{d}</span></small> ", .{st.behind}) catch {};
            }
            if (st.added > 0 or st.removed > 0) {
                w.print("<small><span foreground='#98c379'>+{d}</span> <span foreground='#e06c75'>-{d}</span></small>", .{ st.added, st.removed }) catch {};
            }
            // Attention badge (OSC-3008): bell glyph in red.
            if (self.pathHasAttention(st.path)) w.print(" <span foreground='#e06c75'>\u{1F514}</span>", .{}) catch {};
            break :blk std.mem.trim(u8, stream.getWritten(), " ");
        };

        // Name label (left): status dot + branch, expanding/ellipsizing.
        const markup = std.fmt.allocPrintSentinel(
            alloc,
            "<span foreground='{s}'>\u{25CF}</span> <span foreground='#bbb'>{s}</span>",
            .{ dot_color, branch_esc },
            0,
        ) catch return row;
        defer alloc.free(markup);

        const label = gtk.Label.new(null);
        label.setMarkup(markup.ptr);
        label.setXalign(0);
        label.as(gtk.Widget).setHexpand(@intFromBool(true));
        label.setEllipsize(.end);
        box.append(label.as(gtk.Widget));

        // Badge label (right): fixed size, right-aligned, never clipped.
        if (badges.len > 0) {
            const badge_z = alloc.dupeZ(u8, badges) catch return row;
            defer alloc.free(badge_z);
            const badge_label = gtk.Label.new(null);
            badge_label.setMarkup(badge_z.ptr);
            badge_label.setXalign(1);
            box.append(badge_label.as(gtk.Widget));
        }

        row.setChild(box.as(gtk.Widget));
        return row;
    }

    /// Row activation: a repo header toggles collapse; a worktree leaf opens
    /// (or focuses) that worktree's tab.
    fn sidebarRowActivated(
        _: *gtk.ListBox,
        row: *gtk.ListBoxRow,
        self: *Window,
    ) callconv(.c) void {
        const priv = self.private();
        const idx = row.getIndex();
        if (idx < 0) return;
        const ri: usize = @intCast(idx);
        if (ri >= priv.sidebar_rows.items.len) return;

        const row_ref = priv.sidebar_rows.items[ri];
        switch (row_ref.kind) {
            // The "Active" header is non-activatable; ignore defensively.
            .active_header => {},
            .active_card => {
                if (row_ref.index >= priv.sidebar_statuses.len) return;
                self.openWorktree(&priv.sidebar_statuses[row_ref.index]);
            },
            .repo_header => {
                if (row_ref.index >= priv.sidebar_statuses.len) return;
                self.toggleRepoCollapsed(priv.sidebar_statuses[row_ref.index].repo_root);
            },
            .worktree => {
                if (row_ref.index >= priv.sidebar_statuses.len) return;
                self.openWorktree(&priv.sidebar_statuses[row_ref.index]);
            },
        }
    }

    /// Toggle the collapsed state of a repo group and rebuild the rows.
    fn toggleRepoCollapsed(self: *Window, repo_root: []const u8) void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        if (priv.sidebar_collapsed.fetchRemove(repo_root)) |kv| {
            alloc.free(kv.key);
        } else {
            const key = alloc.dupe(u8, repo_root) catch return;
            priv.sidebar_collapsed.put(alloc, key, {}) catch {
                alloc.free(key);
                return;
            };
        }
        self.rebuildSidebarRows();
    }

    /// Open a worktree's tab space (#7, Option A). Each worktree owns its own
    /// Adw.TabView: selecting a worktree in the sidebar swaps the visible view
    /// to that worktree's tabs (creating the view + an initial tab on first
    /// visit). This matches macOS supacode where a worktree keeps a persistent
    /// set of terminal tabs (Worktree.ID -> [TerminalTabID]); the user can open
    /// many tabs/splits under one folder, not just one.
    fn openWorktree(self: *Window, st: *const sidebar.WorktreeStatus) void {
        const view = self.ensureWorktreeView(st.path);
        const had_tabs = view.getNPages() > 0;
        self.switchToWorktreeView(view);

        // First visit: open an initial terminal in the worktree's cwd.
        if (!had_tabs) {
            self.newTabForWindow(null, .{ .working_directory = st.path });
        }
    }

    /// Whether any surface flagged for attention maps to `path`. Drives the
    /// sidebar bell so two surfaces sharing a worktree aggregate correctly.
    fn pathHasAttention(self: *Window, path: []const u8) bool {
        var it = self.private().sidebar_attention.valueIterator();
        while (it.next()) |v| {
            if (std.mem.eql(u8, v.*, path)) return true;
        }
        return false;
    }

    /// Flag (or clear) a surface as needing attention, recording its worktree
    /// path. Called from the OSC-3008 context_signal handler. Attention is
    /// keyed by surface (not path) so two surfaces on the same worktree don't
    /// clear each other's bell (trio MAJOR M2). Rebuilds the sidebar so the
    /// badge updates immediately.
    pub fn setSurfaceAttention(self: *Window, surface: *Surface, path: []const u8, active: bool) void {
        const priv = self.private();
        const alloc = Application.default().allocator();

        if (active) {
            const dup = alloc.dupeZ(u8, path) catch return;
            const gop = priv.sidebar_attention.getOrPut(alloc, surface) catch {
                alloc.free(dup);
                return;
            };
            if (gop.found_existing) {
                // Update the stored path (cwd may have changed).
                alloc.free(gop.value_ptr.*);
            }
            gop.value_ptr.* = dup;
        } else {
            if (priv.sidebar_attention.fetchRemove(surface)) |kv| {
                alloc.free(kv.value);
            } else return;
        }

        self.rebuildSidebarRows();
    }

    /// Clear any attention flag for a surface (teardown). Returns true if one
    /// was present.
    fn clearSurfaceAttention(self: *Window, surface: *Surface) bool {
        const priv = self.private();
        const alloc = Application.default().allocator();
        if (priv.sidebar_attention.fetchRemove(surface)) |kv| {
            alloc.free(kv.value);
            return true;
        }
        return false;
    }

    /// Supacode agent presence: attach (or detach) an agent to a surface.
    /// Called from the OSC-3008 context_signal handler when an `agent=<name>`
    /// metadata field is present. `surface` is keyed by pointer (stable). On
    /// attach we record the agent; on detach we remove it. Either way we
    /// refresh the indicator icon of the surface's tab.
    pub fn setSurfaceAgent(self: *Window, surface: *Surface, agent: ?agentpkg.Agent) void {
        const priv = self.private();
        const alloc = Application.default().allocator();

        if (agent) |a| {
            // Resolve the owning worktree path NOW, while the surface is live,
            // and cache it on the entry. Teardown paths then decrement the
            // per-worktree count without walking a half-destroyed ancestry.
            const path: ?[:0]u8 = if (self.worktreePathForSurface(surface)) |wp|
                (alloc.dupeZ(u8, wp) catch null)
            else
                null;
            const gop = priv.surface_agents.getOrPut(alloc, surface) catch {
                if (path) |p| alloc.free(p);
                return;
            };
            if (gop.found_existing) {
                // Re-attach on the same surface: drop the previous worktree
                // count + path before recording the new one.
                if (gop.value_ptr.path) |old| {
                    self.decrWorktreeAgent(old);
                    alloc.free(old);
                }
            }
            gop.value_ptr.* = .{
                .agent = a,
                .path = path,
                // Preserve activity + pid across a re-attach on the same surface.
                .activity = if (gop.found_existing) gop.value_ptr.activity else .idle,
                .pid = if (gop.found_existing) gop.value_ptr.pid else null,
            };
            if (path) |p| self.incrWorktreeAgent(p, a);
        } else {
            _ = self.removeSurfaceAgent(surface);
        }

        self.refreshTabAgentIcon(surface);
        // Refresh the sidebar so the Active section tracks agent attach/detach.
        self.rebuildSidebarRows();
    }

    /// Remove a surface's agent entry, decrementing its worktree count and
    /// freeing the cached path. Returns true if an entry was present. The
    /// single chokepoint for agent removal so the per-worktree count (#22) and
    /// the owned path are always kept consistent. Does NOT rebuild the sidebar;
    /// callers batch that.
    fn removeSurfaceAgent(self: *Window, surface: *Surface) bool {
        const priv = self.private();
        const alloc = Application.default().allocator();
        const kv = priv.surface_agents.fetchRemove(surface) orelse return false;
        if (kv.value.path) |p| {
            self.decrWorktreeAgent(p);
            alloc.free(p);
        }
        return true;
    }

    /// Clear any agent presence recorded for a surface. Called on surface
    /// teardown so a crashed/exited agent doesn't leave a stale tab icon
    /// (trio footgun #1: missing end-events leak icons).
    pub fn clearSurfaceAgent(self: *Window, surface: *Surface) void {
        if (self.removeSurfaceAgent(surface)) {
            self.refreshTabAgentIcon(surface);
            self.rebuildSidebarRows();
        }
    }

    /// Whether an agent is currently attached to `surface` (presence on). Used
    /// by the OSC-3008 handler to auto-seed presence on a busy/awaiting_input
    /// event that arrives without a prior session_start (mirrors
    /// AgentPresenceFeature.applyActivity's pid-less auto-seed).
    pub fn surfaceHasAgent(self: *Window, surface: *Surface) bool {
        return self.private().surface_agents.contains(surface);
    }

    /// Set the activity state for an agent attached to `surface`. No-op if no
    /// agent is present. Mirrors AgentPresenceFeature's atomic activity set
    /// (busy/idle/awaiting_input). Rebuilds the sidebar so the worktree's
    /// working indicator tracks the change.
    pub fn setSurfaceActivity(self: *Window, surface: *Surface, activity: agentpkg.Activity) void {
        const priv = self.private();
        const entry = priv.surface_agents.getPtr(surface) orelse return;
        if (entry.activity == activity) return;
        entry.activity = activity;
        self.rebuildSidebarRows();
    }

    /// Record the agent's local pid for the liveness sweep. The pid is carried
    /// in the OSC `pid=` field only on the local host (omitted over SSH), so a
    /// null pid means "nothing to sweep". No-op if no agent is attached.
    /// Mirrors AgentPresenceFeature.PresenceRecord.pids.
    pub fn setSurfaceAgentPid(self: *Window, surface: *Surface, pid: ?std.posix.pid_t) void {
        const priv = self.private();
        const entry = priv.surface_agents.getPtr(surface) orelse return;
        entry.pid = pid;
    }

    /// Recompute and apply the indicator icon for the tab that owns `surface`.
    /// The tab shows the agent of its FOCUSED surface; if that surface has no
    /// agent we fall back to any agent present on another surface in the same
    /// tab (most-recent-wins is approximated by focused-first). One icon per
    /// tab (req 3).
    fn refreshTabAgentIcon(self: *Window, surface: *Surface) void {
        const priv = self.private();

        // Find the Tab that owns this surface, then its TabPage.
        const tab = ext.getAncestor(Tab, surface.as(gtk.Widget)) orelse return;
        const page = self.viewForTab(tab).getPage(tab.as(gtk.Widget));

        // Prefer the focused surface's agent; else the first surface in the tab
        // that has one.
        const chosen: ?agentpkg.Agent = blk: {
            if (tab.getActiveSurface()) |active| {
                if (priv.surface_agents.get(active)) |e| break :blk e.agent;
            }
            // Fall back: scan this tab's surfaces for any recorded agent.
            var it = priv.surface_agents.iterator();
            while (it.next()) |entry| {
                const s = entry.key_ptr.*;
                if (ext.getAncestor(Tab, s.as(gtk.Widget))) |t| {
                    if (t == tab) break :blk entry.value_ptr.agent;
                }
            }
            break :blk null;
        };

        if (chosen) |a| {
            if (a.newIcon()) |icon| {
                defer icon.unref();
                page.setIndicatorIcon(icon);
                page.setIndicatorTooltip(a.label().ptr);
            }
        } else {
            page.setIndicatorIcon(null);
            page.setIndicatorTooltip("");
        }
    }

    /// Show the top-of-window agent attention banner (req 4). `title` is the
    /// agent label; `detail` is optional metadata shown after it. The banner's
    /// "Open" button teleports focus to `surface`.
    pub fn showAgentBanner(
        self: *Window,
        surface: *Surface,
        title: []const u8,
        detail: []const u8,
    ) void {
        const priv = self.private();
        const alloc = Application.default().allocator();

        priv.agent_banner_surface = surface;

        // The banner title is parsed as Pango markup, so escape the detail
        // (assistant text may contain < & etc.) before composing (trio m1).
        const trimmed = trimFirstLine(detail);
        const text: [:0]const u8 = blk: {
            if (trimmed.len > 0) {
                const dz = alloc.dupeZ(u8, trimmed) catch break :blk null;
                defer alloc.free(dz);
                const esc = glib.markupEscapeText(dz.ptr, -1);
                defer glib.free(esc);
                break :blk std.fmt.allocPrintSentinel(
                    alloc,
                    "{s} \u{2014} {s}",
                    .{ title, std.mem.sliceTo(esc, 0) },
                    0,
                ) catch null;
            }
            break :blk std.fmt.allocPrintSentinel(
                alloc,
                "{s} needs attention",
                .{title},
                0,
            ) catch null;
        } orelse (alloc.dupeZ(u8, "Agent needs attention") catch return);
        defer alloc.free(text);

        priv.agent_banner.setTitle(text.ptr);
        priv.agent_banner.setRevealed(@intFromBool(true));
    }

    /// Hide the agent attention banner and forget its target surface.
    pub fn hideAgentBanner(self: *Window) void {
        const priv = self.private();
        priv.agent_banner.setRevealed(@intFromBool(false));
        priv.agent_banner_surface = null;
    }

    /// Hide the banner only if it currently points at `surface`. Lets one
    /// surface's `end` dismiss its own banner without clobbering a banner that
    /// another, still-waiting surface raised.
    pub fn hideAgentBannerFor(self: *Window, surface: *Surface) void {
        if (self.private().agent_banner_surface == surface) self.hideAgentBanner();
    }

    /// Supacode (#11): append an agent attention event to the notification
    /// bell history and refresh the popover. `title` is the agent label;
    /// `detail` is optional metadata (first line shown). The banner is the
    /// transient surface for this same event; the bell is the persistent log.
    pub fn pushNotification(
        self: *Window,
        surface: *Surface,
        title: []const u8,
        detail: []const u8,
    ) void {
        const priv = self.private();
        const alloc = Application.default().allocator();

        // The worktree path lets the popover row navigate back to the surface.
        const pwd = surface.getPwd() orelse "";
        const path = alloc.dupeZ(u8, pwd) catch return;

        // Compose "<agent> — <first line>" (or "<agent> needs attention").
        const trimmed = trimFirstLine(detail);
        const text: [:0]u8 = blk: {
            if (trimmed.len > 0) {
                break :blk std.fmt.allocPrintSentinel(
                    alloc,
                    "{s} \u{2014} {s}",
                    .{ title, trimmed },
                    0,
                ) catch {
                    alloc.free(path);
                    return;
                };
            }
            break :blk std.fmt.allocPrintSentinel(
                alloc,
                "{s} needs attention",
                .{title},
                0,
            ) catch {
                alloc.free(path);
                return;
            };
        };

        priv.notifications.append(alloc, .{
            .path = path,
            .text = text,
            .read = false,
        }) catch {
            alloc.free(path);
            alloc.free(text);
            return;
        };

        // Cap history so a long-running session doesn't grow unbounded.
        const max_history = 100;
        while (priv.notifications.items.len > max_history) {
            const oldest = priv.notifications.orderedRemove(0);
            oldest.deinit(alloc);
        }

        self.refreshNotifications();
    }

    /// Rebuild the notification popover list and update the bell's unread
    /// state. Shows an empty-state label when there are no notifications.
    fn refreshNotifications(self: *Window) void {
        const priv = self.private();
        const alloc = Application.default().allocator();

        priv.notification_list.removeAll();

        const count = priv.notifications.items.len;
        priv.notification_empty.as(gtk.Widget).setVisible(@intFromBool(count == 0));
        priv.notification_list.as(gtk.Widget).setVisible(@intFromBool(count != 0));
        priv.notification_clear_button.as(gtk.Widget).setSensitive(@intFromBool(count != 0));

        var unread: usize = 0;
        // Newest first.
        var i: usize = count;
        while (i > 0) {
            i -= 1;
            const n = priv.notifications.items[i];
            if (!n.read) unread += 1;

            const row = gtk.ListBoxRow.new();
            const box = gtk.Box.new(.horizontal, 8);
            box.as(gtk.Widget).setMarginStart(8);
            box.as(gtk.Widget).setMarginEnd(8);
            box.as(gtk.Widget).setMarginTop(6);
            box.as(gtk.Widget).setMarginBottom(6);

            const dot_color: []const u8 = if (n.read) "#666" else "#e5c07b";
            // Build the dot markup BEFORE creating any widget so an OOM here
            // can't strand an unparented floating Label (trio nit).
            const dot_markup = std.fmt.allocPrintSentinel(
                alloc,
                "<span foreground='{s}'>\u{25CF}</span>",
                .{dot_color},
                0,
            ) catch {
                row.setChild(box.as(gtk.Widget));
                priv.notification_list.append(row.as(gtk.Widget));
                continue;
            };
            defer alloc.free(dot_markup);
            const dot = gtk.Label.new(null);
            dot.setMarkup(dot_markup.ptr);
            dot.as(gtk.Widget).setValign(.start);
            box.append(dot.as(gtk.Widget));

            const label = gtk.Label.new(n.text.ptr);
            label.setXalign(0);
            label.as(gtk.Widget).setHexpand(@intFromBool(true));
            label.setWrap(@intFromBool(true));
            label.setLines(2);
            label.setEllipsize(.end);
            if (n.read) label.as(gtk.Widget).addCssClass("dim-label");
            box.append(label.as(gtk.Widget));

            row.setChild(box.as(gtk.Widget));
            priv.notification_list.append(row.as(gtk.Widget));
        }

        // Bell icon reflects unread state (badge tint via CSS class).
        if (unread > 0) {
            priv.notification_button.as(gtk.Widget).addCssClass("has-notifications");
        } else {
            priv.notification_button.as(gtk.Widget).removeCssClass("has-notifications");
        }
    }

    /// Map a popover ListBox row index back to a notification (newest-first
    /// display order) and navigate to its worktree, marking it read.
    fn notificationRowActivated(
        _: *gtk.ListBox,
        row: *gtk.ListBoxRow,
        self: *Window,
    ) callconv(.c) void {
        const priv = self.private();
        const idx = row.getIndex();
        if (idx < 0) return;
        const display_i: usize = @intCast(idx);
        const count = priv.notifications.items.len;
        if (display_i >= count) return;
        // Rows are newest-first; map back to storage order.
        const store_i = count - 1 - display_i;

        const n = &priv.notifications.items[store_i];
        n.read = true;
        const path = n.path;

        // Navigate to the worktree the notification came from, if known.
        if (path.len > 0) {
            for (priv.sidebar_statuses) |*st| {
                if (std.mem.eql(u8, st.path, path)) {
                    self.openWorktree(st);
                    break;
                }
            }
        }

        // Close the popover and refresh read state.
        priv.notification_button.popdown();
        self.refreshNotifications();
    }

    /// "Clear All" clicked in the popover: drop the whole history.
    fn notificationClearClicked(_: *gtk.Button, self: *Window) callconv(.c) void {
        self.clearNotifications();
        self.private().notification_button.popdown();
    }

    /// Free and empty the notification history, then refresh the popover.
    fn clearNotifications(self: *Window) void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        for (priv.notifications.items) |*n| n.deinit(alloc);
        priv.notifications.clearRetainingCapacity();
        self.refreshNotifications();
    }

    /// Return the first non-empty line of `s` (up to a newline), trimmed.
    fn trimFirstLine(s: []const u8) []const u8 {
        const line = if (std.mem.indexOfScalar(u8, s, '\n')) |nl| s[0..nl] else s;
        return std.mem.trim(u8, line, " \t\r");
    }

    /// Banner "Open" clicked: teleport to the surface that raised the signal
    /// (focus its tab + surface) and dismiss the banner.
    fn agentBannerClicked(_: *adw.Banner, self: *Window) callconv(.c) void {
        const priv = self.private();
        if (priv.agent_banner_surface) |surface| {
            if (ext.getAncestor(Tab, surface.as(gtk.Widget))) |tab| {
                const view = self.viewForTab(tab);
                const page = view.getPage(tab.as(gtk.Widget));
                // Surface lives in a (possibly non-active) worktree view: make
                // that view active first, then select the page.
                self.switchToWorktreeView(view);
                view.setSelectedPage(page);
                _ = surface.as(gtk.Widget).grabFocus();
            }
        }
        self.hideAgentBanner();
    }

    fn btnNewTab(_: *adw.SplitButton, self: *Self) callconv(.c) void {
        self.performBindingAction(.new_tab);
    }

    fn tabOverviewCreateTab(
        _: *adw.TabOverview,
        self: *Self,
    ) callconv(.c) *adw.TabPage {
        return self.newTabPage(if (self.getActiveSurface()) |v| v.core() else null, .tab, .none);
    }

    fn tabOverviewOpen(
        tab_overview: *adw.TabOverview,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // We only care about when the tab overview is closed.
        if (tab_overview.getOpen() != 0) return;

        // On tab overview close, focus is sometimes lost. This is an
        // upstream issue in libadwaita[1]. When this is resolved we
        // can put a runtime version check here to avoid this workaround.
        //
        // Our workaround is to start a timer after 500ms to refocus
        // the currently selected tab. We choose 500ms because the adw
        // animation is 400ms.
        //
        // [1]: https://gitlab.gnome.org/GNOME/libadwaita/-/issues/670

        // If we have an old timer remove it
        const priv = self.private();
        if (priv.tab_overview_focus_timer) |timer| {
            _ = glib.Source.remove(timer);
        }

        // Restart our timer
        priv.tab_overview_focus_timer = glib.timeoutAdd(
            500,
            tabOverviewFocusTimer,
            self,
        );
    }

    fn tabOverviewFocusTimer(
        ud: ?*anyopaque,
    ) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));

        // Always note our timer is removed
        self.private().tab_overview_focus_timer = null;

        // Get our currently active surface which should respect the newly
        // selected tab. Grab focus.
        const surface = self.getActiveSurface() orelse return 0;
        surface.grabFocus();

        // Remove the timer
        return 0;
    }

    fn windowCloseRequest(
        _: *gtk.Window,
        self: *Self,
    ) callconv(.c) c_int {
        if (self.getNeedsConfirmQuit()) {
            // Show a confirmation dialog
            const dialog: *CloseConfirmationDialog = .new(.window);
            _ = CloseConfirmationDialog.signals.@"close-request".connect(
                dialog,
                *Self,
                closeConfirmationClose,
                self,
                .{},
            );

            // Show it
            dialog.present(self.as(gtk.Widget));
            return @intFromBool(true);
        }

        self.as(gtk.Window).destroy();
        return @intFromBool(false);
    }

    fn closeConfirmationClose(
        _: *CloseConfirmationDialog,
        self: *Self,
    ) callconv(.c) void {
        self.as(gtk.Window).destroy();
    }

    fn closeConfirmationCloseTab(
        _: *CloseConfirmationDialog,
        page: *adw.TabPage,
    ) callconv(.c) void {
        const tab_view = ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        ) orelse {
            log.warn("close confirmation called for non-existent page", .{});
            return;
        };
        tab_view.closePageFinish(page, @intFromBool(true));
    }

    fn closeConfirmationCancelTab(
        _: *CloseConfirmationDialog,
        page: *adw.TabPage,
    ) callconv(.c) void {
        const tab_view = ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        ) orelse {
            log.warn("close confirmation called for non-existent page", .{});
            return;
        };
        tab_view.closePageFinish(page, @intFromBool(false));
    }

    fn tabViewClosePage(
        view: *adw.TabView,
        page: *adw.TabPage,
        self: *Self,
    ) callconv(.c) c_int {
        // During teardown, let pages close without our bookkeeping.
        if (self.private().disposing) {
            view.closePageFinish(page, @intFromBool(true));
            return @intFromBool(true);
        }
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse
            return @intFromBool(false);

        // `view` is the emitting TabView (the worktree space that owns this
        // page), so close operates on the correct space directly (#7).
        // If the tab says it doesn't need confirmation then we go ahead
        // and close immediately.
        if (!tab.getNeedsConfirmQuit()) {
            view.closePageFinish(page, @intFromBool(true));
            return @intFromBool(true);
        }

        // Show a confirmation dialog
        const dialog: *CloseConfirmationDialog = .new(.tab);
        _ = CloseConfirmationDialog.signals.@"close-request".connect(
            dialog,
            *adw.TabPage,
            closeConfirmationCloseTab,
            page,
            .{},
        );
        _ = CloseConfirmationDialog.signals.cancel.connect(
            dialog,
            *adw.TabPage,
            closeConfirmationCancelTab,
            page,
            .{},
        );

        // Show it
        dialog.present(child);
        return @intFromBool(true);
    }

    fn tabViewSelectedPage(
        view: *adw.TabView,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // Skip during teardown: the binding group and child views are being
        // torn down (#7 review: guard all per-view handlers symmetrically).
        if (self.private().disposing) return;
        // Only the active (visible) view drives the window title binding and
        // attention clearing. A background worktree view emitting selected-page
        // (e.g. during drag-detach) must not retarget the title or clear the
        // active page's attention (#7 review: emitting-view awareness).
        if (view != self.activeTabView()) return;
        self.refreshActiveTabBinding();
    }

    fn tabViewPageAttached(
        _: *adw.TabView,
        page: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        if (self.private().disposing) return;
        // Get the attached page which must be a Tab object.
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;

        // Attach listeners for the tab.
        _ = Tab.signals.@"close-request".connect(
            tab,
            *Self,
            tabCloseRequest,
            self,
            .{},
        );

        // Attach listeners for the surface.
        //
        // Interesting behavior here that was previously undocumented but
        // I'm going to make it explicit here: we accept all the signals here
        // (like toggle-fullscreen) regardless of whether the surface or tab
        // is focused. At the time of writing this we have no API that could
        // really trigger these that way but its theoretically possible.
        //
        // What is DEFINITELY possible is something like OSC52 triggering
        // a clipboard-write signal on an unfocused tab/surface. We definitely
        // want to show the user a notification about that but our notification
        // right now is a toast that doesn't make it clear WHO used the
        // clipboard. We probably want to change that in the future.
        //
        // I'm not sure how desirable all the above is, and we probably
        // should be thoughtful about future signals here. But all of this
        // behavior is consistent with macOS and the previous GTK apprt,
        // but that behavior was all implicit and not documented, so here
        // I am.
        if (tab.getSurfaceTree()) |tree| {
            self.connectSurfaceHandlers(tree);
        }
    }

    fn tabViewPageDetached(
        _: *adw.TabView,
        page: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        // During window teardown the per-tab agent/attention maps are being
        // freed in dispose(); skip touching them to avoid use-after-free as
        // the stack disposes its child views (#7 review Finding 7).
        if (self.private().disposing) return;
        // We need to get the tab to disconnect the signals.
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;
        _ = gobject.signalHandlersDisconnectMatched(
            tab.as(gobject.Object),
            .{ .data = true },
            0,
            0,
            null,
            null,
            self,
        );

        // Remove the tree handlers
        if (tab.getSurfaceTree()) |tree| {
            self.disconnectSurfaceHandlers(tree);
        }

        // Supacode: clear agent presence for any surface in this tab so a
        // closed tab doesn't leave a stale icon or dangling banner target
        // (trio footgun #1: missing end-events leak presence).
        self.clearTabAgents(tab);
    }

    /// Remove all agent presence AND attention entries that belong to `tab`,
    /// and clear the banner if it pointed at one of them. Called on tab
    /// detach so a closed tab leaves no stale icon, bell, or dangling banner
    /// target (trio footgun #1 / CRITICAL C1).
    fn clearTabAgents(self: *Window, tab: *Tab) void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        var to_remove: std.ArrayListUnmanaged(*Surface) = .empty;
        defer to_remove.deinit(alloc);

        // Collect surfaces in this tab from the presence map.
        var it = priv.surface_agents.iterator();
        while (it.next()) |entry| {
            const s = entry.key_ptr.*;
            if (ext.getAncestor(Tab, s.as(gtk.Widget))) |t| {
                if (t == tab) to_remove.append(alloc, s) catch {};
            } else {
                // Surface no longer has a tab ancestor (being torn down): drop.
                to_remove.append(alloc, s) catch {};
            }
        }
        // ...and from the attention map.
        var ait = priv.sidebar_attention.iterator();
        while (ait.next()) |entry| {
            const s = entry.key_ptr.*;
            const same = if (ext.getAncestor(Tab, s.as(gtk.Widget))) |t| t == tab else true;
            if (same) {
                // Avoid duplicates; cheap linear check (sets are tiny).
                var dup = false;
                for (to_remove.items) |x| {
                    if (x == s) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) to_remove.append(alloc, s) catch {};
            }
        }

        var changed = false;
        for (to_remove.items) |s| {
            // Removing agent presence must also refresh the sidebar so a
            // worktree leaves the "Active" section when its last agent ends
            // (#22). removeSurfaceAgent decrements the per-worktree count.
            if (self.removeSurfaceAgent(s)) changed = true;
            if (self.clearSurfaceAttention(s)) changed = true;
            if (priv.agent_banner_surface == s) self.hideAgentBanner();
        }
        if (changed) self.rebuildSidebarRows();
    }

    fn tabViewCreateWindow(
        _: *adw.TabView,
        _: *Self,
    ) callconv(.c) *adw.TabView {
        // Create a new window without creating a new tab.
        const win = gobject.ext.newInstance(
            Self,
            .{
                .application = Application.default(),
            },
        );

        // We have to show it otherwise it'll just be hidden.
        gtk.Window.present(win.as(gtk.Window));

        // Get our tab view
        return win.private().tab_view;
    }

    fn tabCloseRequest(
        tab: *Tab,
        self: *Self,
    ) callconv(.c) void {
        const view = self.viewForTab(tab);
        const page = view.getPage(tab.as(gtk.Widget));
        // TODO: connect close page handler to tab to check for confirmation
        view.closePage(page);
    }

    fn tabViewNPages(
        view: *adw.TabView,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // During teardown the stack disposes its child TabViews, which emits
        // notify::n-pages. Don't re-enter window-close logic then (#7 review:
        // dispose re-entrancy).
        if (priv.disposing) return;

        if (self.totalTabPages() == 0) {
            // If we have no pages left then we want to close window.

            // If the tab overview is open, then we don't close the window
            // because its a rather abrupt experience. This also fixes an
            // issue where dragging out the last tab in the tab overview
            // won't cause Ghostty to exit.
            if (priv.tab_overview.getOpen() != 0) return;

            self.as(gtk.Window).close();
            return;
        }

        // The emitting view just emptied but other worktree spaces still have
        // tabs: don't strand the user on a blank pane. Switch to a non-empty
        // view (#7 review: empty-active-view dead-end).
        if (view == self.activeTabView() and view.getNPages() == 0) {
            var it = priv.worktree_views.valueIterator();
            while (it.next()) |v_ptr| {
                const v = v_ptr.*;
                if (v != view and v.getNPages() > 0) {
                    self.switchToWorktreeView(v);
                    break;
                }
            }
        }
    }
    fn setupTabMenu(
        _: *adw.TabView,
        page: ?*adw.TabPage,
        self: *Self,
    ) callconv(.c) void {
        self.private().context_menu_page = page;
    }

    fn surfaceClipboardWrite(
        _: *Surface,
        clipboard_type: apprt.Clipboard,
        text: [*:0]const u8,
        self: *Self,
    ) callconv(.c) void {
        // We only toast for the standard clipboard.
        if (clipboard_type != .standard) return;

        // We only toast if configured to
        const priv = self.private();
        const config_obj = priv.config orelse return;
        const config = config_obj.get();
        if (!config.@"app-notifications".@"clipboard-copy") {
            return;
        }

        if (text[0] != 0)
            self.addToast(i18n._("Copied to clipboard"))
        else
            self.addToast(i18n._("Cleared clipboard"));
    }

    fn surfaceMenu(
        _: *Surface,
        self: *Self,
    ) callconv(.c) void {
        self.syncActions();
    }

    fn surfacePresentRequest(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        // Verify that this surface is actually in this window.
        {
            const surface_window = ext.getAncestor(
                Self,
                surface.as(gtk.Widget),
            ) orelse {
                log.warn(
                    "present request called for non-existent surface",
                    .{},
                );
                return;
            };
            if (surface_window != self) {
                log.warn(
                    "present request called for surface in different window",
                    .{},
                );
                return;
            }
        }

        // Get the tab for this surface.
        const tab = ext.getAncestor(
            Tab,
            surface.as(gtk.Widget),
        ) orelse {
            log.warn("present request surface not found", .{});
            return;
        };

        // Get the page that contains this tab
        const tab_view = self.viewForTab(tab);
        const page = tab_view.getPage(tab.as(gtk.Widget));
        self.switchToWorktreeView(tab_view);
        tab_view.setSelectedPage(page);

        // Grab focus
        surface.grabFocus();

        // Bring the window to the front.
        self.as(gtk.Window).present();
    }

    fn surfaceToggleFullscreen(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        _ = surface;
        if (self.as(gtk.Window).isFullscreen() != 0) {
            self.as(gtk.Window).unfullscreen();
        } else {
            self.as(gtk.Window).fullscreen();
        }

        // We react to the changes in the propFullscreen callback
    }

    fn surfaceToggleMaximize(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        _ = surface;
        if (self.as(gtk.Window).isMaximized() != 0) {
            self.as(gtk.Window).unmaximize();
        } else {
            self.as(gtk.Window).maximize();
        }

        // We react to the changes in the propMaximized callback
    }

    fn surfaceInit(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // Make sure we init only once
        if (priv.surface_init) return;
        priv.surface_init = true;

        // Setup our default and minimum size.
        if (surface.getDefaultSize()) |size| {
            self.as(gtk.Window).setDefaultSize(
                @intCast(size.width),
                @intCast(size.height),
            );
        }
        if (surface.getMinSize()) |size| {
            self.as(gtk.Widget).setSizeRequest(
                @intCast(size.width),
                @intCast(size.height),
            );
        }
    }

    /// The focused surface within a tab changed (e.g. the user moved focus
    /// between panes of a split). Re-derive the tab's agent indicator icon so
    /// it tracks the focused pane (stage-8). `refreshTabAgentIcon` resolves the
    /// owning tab from the surface and prefers that tab's active surface, with
    /// a fallback to any agent present in the tab.
    fn tabActiveSurfaceChanged(
        tab: *Tab,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const surface = tab.getActiveSurface() orelse return;
        self.refreshTabAgentIcon(surface);
    }

    fn tabSplitTreeChanged(
        _: *SplitTree,
        old_tree: ?*const Surface.Tree,
        new_tree: ?*const Surface.Tree,
        self: *Self,
    ) callconv(.c) void {
        var changed = false;
        if (old_tree) |tree| {
            self.disconnectSurfaceHandlers(tree);

            // Prune agent/banner state for any surface that left the tree
            // (e.g. a split pane closed without the whole tab closing). The
            // surface widget is about to be destroyed, so leaving a raw
            // *Surface key in surface_agents or as the banner target would
            // dangle and later cause a use-after-free in refreshTabAgentIcon
            // / agentBannerClicked (trio CRITICAL C1).
            var it = tree.iterator();
            while (it.next()) |entry| {
                const surface = entry.view;
                if (new_tree) |nt| {
                    if (treeContains(nt, surface)) continue;
                }
                if (self.removeSurfaceAgent(surface)) changed = true;
                _ = self.clearSurfaceAttention(surface);
                if (self.private().agent_banner_surface == surface) {
                    self.hideAgentBanner();
                }
            }
        }

        if (new_tree) |tree| {
            self.connectSurfaceHandlers(tree);
        }

        // A split pane carrying an agent may have closed without the whole
        // tab closing; refresh the sidebar so its worktree leaves "Active"
        // when its last agent is gone (#22).
        if (changed) self.rebuildSidebarRows();
    }

    /// Whether `surface` is present in `tree`.
    fn treeContains(tree: *const Surface.Tree, surface: *Surface) bool {
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.view == surface) return true;
        }
        return false;
    }

    fn actionAbout(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const name = "Ghostty";
        const icon = "com.mitchellh.ghostty";
        const website = "https://ghostty.org";

        if (adw_version.supportsDialogs()) {
            adw.showAboutDialog(
                self.as(gtk.Widget),
                "application-name",
                name,
                "developer-name",
                i18n._("Ghostty Developers"),
                "application-icon",
                icon,
                "version",
                build_config.version_string.ptr,
                "issue-url",
                "https://github.com/ghostty-org/ghostty/issues",
                "website",
                website,
                @as(?*anyopaque, null),
            );
        } else {
            gtk.showAboutDialog(
                self.as(gtk.Window),
                "program-name",
                name,
                "logo-icon-name",
                icon,
                "title",
                i18n._("About Ghostty"),
                "version",
                build_config.version_string.ptr,
                "website",
                website,
                @as(?*anyopaque, null),
            );
        }
    }

    fn actionClose(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.as(gtk.Window).close();
    }

    fn actionCloseTab(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        const param = param_ orelse {
            log.warn("win.close-tab called without a parameter", .{});
            return;
        };

        var str: ?[*:0]const u8 = null;
        param.get("&s", &str);

        const mode = std.meta.stringToEnum(
            input.Binding.Action.CloseTabMode,
            std.mem.span(
                str orelse {
                    log.warn("invalid mode provided to win.close-tab", .{});
                    return;
                },
            ),
        ) orelse {
            log.warn("invalid mode provided to win.close-tab: {s}", .{str.?});
            return;
        };

        self.performBindingAction(.{ .close_tab = mode });
    }

    fn actionNewWindow(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.new_window);
    }

    fn actionNewTab(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.new_tab);
    }

    fn actionPromptContextTabTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const page = priv.context_menu_page orelse return;
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;
        tab.promptTabTitle();
    }

    fn actionPromptSurfaceTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.prompt_surface_title);
    }

    fn actionPromptTabTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.prompt_tab_title);
    }

    fn actionSplitRight(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .right });
    }

    fn actionSplitLeft(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .left });
    }

    fn actionSplitUp(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .up });
    }

    fn actionSplitDown(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .down });
    }

    fn actionCopy(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .copy_to_clipboard = .mixed });
    }

    fn actionPaste(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.paste_from_clipboard);
    }

    fn actionReset(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.reset);
    }

    fn actionClear(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.clear_screen);
    }

    fn actionRingBell(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return;

        if (config.@"bell-features".system) system: {
            const native = self.as(gtk.Native).getSurface() orelse {
                log.warn("unable to get native surface from window", .{});
                break :system;
            };
            native.beep();
        }

        if (config.@"bell-features".attention) attention: {
            // Dont set urgency if the window is already active.
            if (self.as(gtk.Window).isActive() != 0) break :attention;

            // Request user attention
            self.winproto().setUrgent(true) catch |err| {
                log.warn("winproto failed to set urgency={}", .{err});
            };
        }
    }

    /// Toggle the command palette.
    ///
    /// TODO: accept the surface that toggled the command palette as a parameter
    fn toggleCommandPalette(self: *Window) void {
        const priv = self.private();

        // Get a reference to a command palette. First check the weak reference
        // that we save to see if we already have one stored. If we don't then
        // create a new one.
        const command_palette = priv.command_palette.get() orelse command_palette: {
            // Create a fresh command palette.
            const command_palette = CommandPalette.new();

            // Synchronize our config to the command palette's config.
            _ = gobject.Object.bindProperty(
                self.as(gobject.Object),
                "config",
                command_palette.as(gobject.Object),
                "config",
                .{ .sync_create = true },
            );

            // Listen to the activate signal to know if the user selected an option in
            // the command palette.
            _ = CommandPalette.signals.trigger.connect(
                command_palette,
                *Window,
                signalCommandPaletteTrigger,
                self,
                .{},
            );

            // Save a weak reference to the command palette. We use a weak reference to avoid
            // reference counting cycles that might cause problems later.
            priv.command_palette.set(command_palette);

            break :command_palette command_palette;
        };
        defer command_palette.unref();

        // Tell the command palette to toggle itself. If the dialog gets
        // presented (instead of hidden) it will be modal over our window.
        command_palette.toggle(self);
    }

    // React to a signal from a command palette asking an action to be performed.
    fn signalCommandPaletteTrigger(_: *CommandPalette, action: *const input.Binding.Action, self: *Self) callconv(.c) void {
        // If the activation actually has an action, perform it.
        self.performBindingAction(action.*);
    }

    /// React to a GTK action requesting that the command palette be toggled.
    fn actionToggleCommandPalette(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        // TODO: accept the surface that toggled the command palette as a
        // parameter
        self.toggleCommandPalette();
    }

    /// Toggle the Ghostty inspector for the active surface.
    fn toggleInspector(self: *Self) void {
        const surface = self.getActiveSurface() orelse return;
        _ = surface.controlInspector(.toggle);
    }

    /// React to a GTK action requesting that the Ghostty inspector be toggled.
    fn actionToggleInspector(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        // TODO: accept the surface that toggled the command palette as a
        // parameter
        self.toggleInspector();
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(DebugWarning);
            gobject.ext.ensureType(SplitTree);
            gobject.ext.ensureType(Surface);
            gobject.ext.ensureType(Tab);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "window",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.config.impl,
                properties.debug.impl,
                properties.@"headerbar-visible".impl,
                properties.@"quick-terminal".impl,
                properties.@"tabs-autohide".impl,
                properties.@"tabs-visible".impl,
                properties.@"tabs-wide".impl,
                properties.@"toolbar-style".impl,
                properties.@"titlebar-style".impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("tab_overview", .{});
            class.bindTemplateChildPrivate("tab_bar", .{});
            class.bindTemplateChildPrivate("tab_view", .{});
            class.bindTemplateChildPrivate("worktree_stack", .{});
            class.bindTemplateChildPrivate("toolbar", .{});
            class.bindTemplateChildPrivate("toast_overlay", .{});
            class.bindTemplateChildPrivate("split_view", .{});
            class.bindTemplateChildPrivate("sidebar_list", .{});
            class.bindTemplateChildPrivate("sidebar_add_button", .{});
            class.bindTemplateChildPrivate("agent_banner", .{});
            class.bindTemplateChildPrivate("identity_chip", .{});
            class.bindTemplateChildPrivate("identity_avatar", .{});
            class.bindTemplateChildPrivate("identity_branch", .{});
            class.bindTemplateChildPrivate("identity_repo", .{});
            class.bindTemplateChildPrivate("notification_button", .{});
            class.bindTemplateChildPrivate("notification_list", .{});
            class.bindTemplateChildPrivate("notification_empty", .{});
            class.bindTemplateChildPrivate("notification_clear_button", .{});

            // Template Callbacks
            class.bindTemplateCallback("realize", &windowRealize);
            class.bindTemplateCallback("sidebar_add_clicked", &sidebarAddClicked);
            class.bindTemplateCallback("agent_banner_clicked", &agentBannerClicked);
            class.bindTemplateCallback("notification_row_activated", &notificationRowActivated);
            class.bindTemplateCallback("notification_clear_clicked", &notificationClearClicked);
            class.bindTemplateCallback("new_tab", &btnNewTab);
            class.bindTemplateCallback("overview_create_tab", &tabOverviewCreateTab);
            class.bindTemplateCallback("overview_notify_open", &tabOverviewOpen);
            class.bindTemplateCallback("close_request", &windowCloseRequest);
            class.bindTemplateCallback("close_page", &tabViewClosePage);
            class.bindTemplateCallback("page_attached", &tabViewPageAttached);
            class.bindTemplateCallback("page_detached", &tabViewPageDetached);
            class.bindTemplateCallback("setup_tab_menu", &setupTabMenu);
            class.bindTemplateCallback("tab_create_window", &tabViewCreateWindow);
            class.bindTemplateCallback("notify_n_pages", &tabViewNPages);
            class.bindTemplateCallback("notify_selected_page", &tabViewSelectedPage);
            class.bindTemplateCallback("notify_config", &propConfig);
            class.bindTemplateCallback("notify_fullscreened", &propFullscreened);
            class.bindTemplateCallback("notify_is_active", &propIsActive);
            class.bindTemplateCallback("notify_maximized", &propMaximized);
            class.bindTemplateCallback("notify_menu_active", &propMenuActive);
            class.bindTemplateCallback("notify_quick_terminal", &propQuickTerminal);
            class.bindTemplateCallback("notify_scale_factor", &propScaleFactor);
            class.bindTemplateCallback("titlebar_style_is_tabs", &closureTitlebarStyleIsTab);

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
