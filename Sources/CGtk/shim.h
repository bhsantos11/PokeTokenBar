/* GTK3 + AppIndicator for the Linux frontend.
   `appindicator3-0.1`'s pkg-config flags already carry the gtk+-3.0 include and
   link flags, so one pkgConfig name covers both headers. */
#include <gtk/gtk.h>
#include <libappindicator/app-indicator.h>

/* The whole GdkPixbufAnimation API is deprecated since gdk-pixbuf 2.44 (19 deprecation markers in
   gdk-pixbuf-animation.h) and there is no in-tree replacement — upstream points at other imaging
   libraries. It is still the only way to decode an animated GIF with what is already linked here,
   and the iterator additionally wants a `GTimeVal`, a type GLib deprecated without gdk-pixbuf ever
   gaining a `GDateTime` overload.

   So the deprecation cannot be avoided, only *contained*. These wrappers keep both the deprecated
   calls and `GTimeVal` out of Swift entirely, take plain microseconds, and silence the warning at
   the one boundary where it is genuinely unavoidable rather than on every build — which is what
   keeps a real warning visible when one appears. Revisit if a supported decoder shows up. */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

static inline GTimeVal ptb_time_from_micros(gint64 micros) {
    GTimeVal time;
    time.tv_sec = (glong)(micros / 1000000);
    time.tv_usec = (glong)(micros % 1000000);
    return time;
}

/* Decode an animation from a loader that has already been written to and closed. */
static inline GdkPixbufAnimation *ptb_loader_animation(GdkPixbufLoader *loader) {
    return gdk_pixbuf_loader_get_animation(loader);
}

/* TRUE when the "animation" is really a single still frame. */
static inline gboolean ptb_animation_is_static(GdkPixbufAnimation *animation) {
    return gdk_pixbuf_animation_is_static_image(animation);
}

/* Milliseconds the current frame should be held, or -1 when the image is not animated. */
static inline int ptb_animation_iter_delay(GdkPixbufAnimationIter *iter) {
    return gdk_pixbuf_animation_iter_get_delay_time(iter);
}

/* The current frame. Borrowed reference, owned by the iterator. */
static inline GdkPixbuf *ptb_animation_iter_pixbuf(GdkPixbufAnimationIter *iter) {
    return gdk_pixbuf_animation_iter_get_pixbuf(iter);
}

/* Start an animation iterator at `micros` into the loop. */
static inline GdkPixbufAnimationIter *ptb_animation_iter(GdkPixbufAnimation *animation, gint64 micros) {
    GTimeVal time = ptb_time_from_micros(micros);
    return gdk_pixbuf_animation_get_iter(animation, &time);
}

/* Advance the iterator to `micros`. Returns TRUE when the displayed frame changed. */
static inline gboolean ptb_animation_iter_advance(GdkPixbufAnimationIter *iter, gint64 micros) {
    GTimeVal time = ptb_time_from_micros(micros);
    return gdk_pixbuf_animation_iter_advance(iter, &time);
}

#pragma GCC diagnostic pop

/* GTK's dialog constructors are variadic and its "interfaces" (GtkFileChooser) are reached through
   cast macros — neither crosses into Swift. These wrappers keep the varargs and the casting on the
   C side, which is also where GTK expects them. */

static inline GtkWidget *ptb_file_chooser_dialog(
    const char *title, GtkWindow *parent, GtkFileChooserAction action,
    const char *cancel_label, const char *accept_label) {
    return gtk_file_chooser_dialog_new(title, parent, action,
                                       cancel_label, GTK_RESPONSE_CANCEL,
                                       accept_label, GTK_RESPONSE_ACCEPT,
                                       NULL);
}

static inline void ptb_chooser_set_current_name(GtkWidget *dialog, const char *name) {
    gtk_file_chooser_set_current_name(GTK_FILE_CHOOSER(dialog), name);
}

static inline void ptb_chooser_confirm_overwrite(GtkWidget *dialog, gboolean confirm) {
    gtk_file_chooser_set_do_overwrite_confirmation(GTK_FILE_CHOOSER(dialog), confirm);
}

/* Caller frees with g_free. */
static inline char *ptb_chooser_filename(GtkWidget *dialog) {
    return gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dialog));
}

/* "%s" rather than passing `text` as the format string — a save path or an error message can
   contain a percent sign, and feeding it to printf would read past the arguments. */
static inline GtkWidget *ptb_message_dialog(
    GtkWindow *parent, GtkMessageType type, GtkButtonsType buttons, const char *text) {
    return gtk_message_dialog_new(parent, GTK_DIALOG_MODAL, type, buttons, "%s", text);
}

static inline int ptb_dialog_run(GtkWidget *dialog) {
    return gtk_dialog_run(GTK_DIALOG(dialog));
}

static inline GtkWidget *ptb_dialog_add_button(GtkWidget *dialog, const char *label, int response) {
    return gtk_dialog_add_button(GTK_DIALOG(dialog), label, response);
}

static inline int ptb_response_accept(void) { return GTK_RESPONSE_ACCEPT; }
static inline int ptb_response_cancel(void) { return GTK_RESPONSE_CANCEL; }
