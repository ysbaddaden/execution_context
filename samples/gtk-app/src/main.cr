require "execution_context"
require "gobject/gtk"
require "wait_group"

module My
  class Window < Gtk::ApplicationWindow
    def build : Nil
      self.titlebar = headerbar
      show_all
    end

    private def headerbar : Gtk::HeaderBar
      @headerbar ||= Gtk::HeaderBar.new(
        title: "My App",
        subtitle: "My Window",
        show_close_button: true
      )
    end
  end

  class Application < Gtk::Application
    @window : Window?
    @activated = Atomic::Flag.new

    def initialize
      super application_id: "org.example.my-app"

      # Gtk only starts one instance of an application, when running it a second
      # time it will notify the running one and trigger the on activate event:
      on_activate do
        if @activated.test_and_set
          # build the window once
          window.build
          window.connect("destroy") { quit }
        else
          # push the existing window on top of other windows
          window.present_with_time(Time.utc.to_unix)
        end
      end
    end

    private def window : Window
      @window ||= Window.new(
        application: self,
        title: "My App",
        default_width: 300,
        default_height: 400,
      )
    end
  end
end

wg = WaitGroup.new(1)

# Spawn a thread to handle the Gtk application which will run the Gtk/GLib event
# loop without blocking the rest of the application.
#
# Gtk events will be handled synchronously in the isolated context, but these
# events can spawn fibers (created in the default context) or communicate
# through a channel to avoid blocking the Gtk loop which would block the UI.
#
# Other contexts can update the UI through callbacks with `GLib.idle_add(&)`
# that will be run the Gtk loop (thus in the isolated context).
ExecutionContext::Isolated.new("GTK") do
  My::Application.new.run
ensure
  wg.done
end

# block the main fiber until the Gtk application exits
wg.wait
