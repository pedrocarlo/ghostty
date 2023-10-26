const Tab = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const font = @import("../../font/main.zig");
const CoreSurface = @import("../../Surface.zig");
const Paned = @import("Paned.zig");
const Parent = @import("relation.zig").Parent;
const Child = @import("relation.zig").Child;
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const c = @import("c.zig");

const log = std.log.scoped(.gtk);

pub const GHOSTTY_TAB = "ghostty_tab";

window: *Window,
label_text: *c.GtkLabel,
close_button: *c.GtkButton,
// We'll put our children into this box instead of packing them directly, so
// that we can send the box into `c.g_signal_connect_data` for the close button
box: *c.GtkBox,
// The child can be either a Surface if the tab is not split or a Paned
child: Child,
// We'll update this every time a Surface gains focus, so that we have it
// when we switch to another Tab. Then when we switch back to this tab, we
// can easily re-focus that terminal.
focus_child: *Surface,

pub fn create(alloc: Allocator, window: *Window, parent_: ?*CoreSurface) !*Tab {
    var tab = try alloc.create(Tab);
    errdefer alloc.destroy(tab);
    try tab.init(window, parent_);
    return tab;
}

pub fn init(self: *Tab, window: *Window, parent_: ?*CoreSurface) !void {
    self.* = .{
        .window = window,
        .label_text = undefined,
        .close_button = undefined,
        .box = undefined,
        .child = undefined,
        .focus_child = undefined,
    };

    // Grab a surface allocation we'll need it later.
    var surface = try window.app.core_app.alloc.create(Surface);
    errdefer window.app.core_app.alloc.destroy(surface);
    self.child = Child{ .surface = surface };
    // TODO: this needs to change
    self.focus_child = surface;

    // Inherit the parent's font size if we are configured to.
    const font_size: ?font.face.DesiredSize = font_size: {
        if (!window.app.config.@"window-inherit-font-size") break :font_size null;
        const parent = parent_ orelse break :font_size null;
        break :font_size parent.font_size;
    };

    // Build the tab label
    const label_box_widget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    const label_box = @as(*c.GtkBox, @ptrCast(label_box_widget));
    const label_text_widget = c.gtk_label_new("Ghostty");
    const label_text: *c.GtkLabel = @ptrCast(label_text_widget);
    self.label_text = label_text;
    c.gtk_box_append(label_box, label_text_widget);
    const label_close_widget = c.gtk_button_new_from_icon_name("window-close");
    const label_close: *c.GtkButton = @ptrCast(label_close_widget);
    c.gtk_button_set_has_frame(label_close, 0);
    c.gtk_box_append(label_box, label_close_widget);
    self.close_button = label_close;

    _ = c.g_signal_connect_data(label_close, "clicked", c.G_CALLBACK(&gtkTabCloseClick), self, null, c.G_CONNECT_DEFAULT);

    // Wide style GTK tabs
    if (window.app.config.@"gtk-wide-tabs") {
        c.gtk_widget_set_hexpand(label_box_widget, 1);
        c.gtk_widget_set_halign(label_box_widget, c.GTK_ALIGN_FILL);
        c.gtk_widget_set_hexpand(label_text_widget, 1);
        c.gtk_widget_set_halign(label_text_widget, c.GTK_ALIGN_FILL);

        // This ensures that tabs are always equal width. If they're too
        // long, they'll be truncated with an ellipsis.
        c.gtk_label_set_max_width_chars(@ptrCast(label_text), 1);
        c.gtk_label_set_ellipsize(@ptrCast(label_text), c.PANGO_ELLIPSIZE_END);

        // We need to set a minimum width so that at a certain point
        // the notebook will have an arrow button rather than shrinking tabs
        // to an unreadably small size.
        c.gtk_widget_set_size_request(@ptrCast(label_text), 100, 1);
    }

    const box_widget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_hexpand(box_widget, 1);
    c.gtk_widget_set_vexpand(box_widget, 1);
    self.box = @ptrCast(box_widget);

    // Initialize the GtkGLArea and attach it to our surface.
    // The surface starts in the "unrealized" state because we have to
    // wait for the "realize" callback from GTK to know that the OpenGL
    // context is ready. See Surface docs for more info.
    const gl_area = c.gtk_gl_area_new();
    c.gtk_widget_set_hexpand(gl_area, 1);
    c.gtk_widget_set_vexpand(gl_area, 1);
    try surface.init(window.app, .{
        .window = window,
        .tab = self,
        .parent = .{ .tab = self },
        .gl_area = @ptrCast(gl_area),
        .title_label = @ptrCast(label_text),
        .font_size = font_size,
    });
    errdefer surface.deinit();

    c.gtk_box_append(self.box, gl_area);
    const page_idx = c.gtk_notebook_append_page(window.notebook, box_widget, label_box_widget);
    if (page_idx < 0) {
        log.warn("failed to add page to notebook", .{});
        return error.GtkAppendPageFailed;
    }

    // Tab settings
    c.gtk_notebook_set_tab_reorderable(window.notebook, box_widget, 1);
    c.gtk_notebook_set_tab_detachable(window.notebook, box_widget, 1);

    // If we have multiple tabs, show the tab bar.
    if (c.gtk_notebook_get_n_pages(window.notebook) > 1) {
        c.gtk_notebook_set_show_tabs(window.notebook, 1);
    }

    // Set the userdata of the box to point to this tab.
    c.g_object_set_data(@ptrCast(box_widget), GHOSTTY_TAB, self);

    // Switch to the new tab
    c.gtk_notebook_set_current_page(window.notebook, page_idx);

    // We need to grab focus after it is added to the window. When
    // creating a window we want to always focus on the widget.
    const widget = @as(*c.GtkWidget, @ptrCast(gl_area));
    _ = c.gtk_widget_grab_focus(widget);
}

pub fn removeChild(self: *Tab) void {
    const widget = self.child.widget() orelse return;
    c.gtk_box_remove(self.box, widget);

    self.child = .none;
}

pub fn setChild(self: *Tab, child: Child) void {
    const widget = child.widget() orelse return;
    c.gtk_box_append(self.box, widget);

    child.setParent(.{ .tab = self });
    self.child = child;
}

fn gtkTabCloseClick(_: *c.GtkButton, ud: ?*anyopaque) callconv(.C) void {
    const tab: *Tab = @ptrCast(@alignCast(ud));
    const window = tab.window;
    window.closeTab(tab);
}

pub fn close(self: *Tab) void {
    switch (self.child) {
        .none => return,
        .surface => {
            // TODO: I'm not 100% but I don't think we have to do something
            return;
        },
        .paned => |paned| {
            paned.deinit(self.window.app.core_app.alloc);
            self.window.app.core_app.alloc.destroy(paned);
        },
    }
}
