//// Outgoing e-mail: login codes and decision notifications. Each send runs
//// in its own unlinked process so a slow SMTP server never blocks a request.

import gleam/dict
import gleam/erlang/process
import huddy/config.{type Config}
import huddy/sys
import logging

pub fn sender(config: Config) -> fn(String, String, String) -> Nil {
  fn(to: String, subject: String, body: String) {
    let from = config.email.from
    case config.email.transport {
      config.LogTransport ->
        logging.log(
          logging.Notice,
          "email (log transport) to " <> to <> " — " <> subject <> "\n" <> body,
        )
      config.Smtp(host:, port:, tls:, username:, password:) -> {
        let opts =
          dict.from_list([
            #(sys.Host, sys.smtp_value(host)),
            #(sys.Port, sys.smtp_value(port)),
            #(sys.Tls, sys.smtp_value(tls)),
            #(sys.Username, sys.smtp_value(username)),
            #(sys.Password, sys.smtp_value(password)),
          ])
        process.spawn_unlinked(fn() {
          case sys.send_email(opts, from, to, subject, body) {
            Ok(_) -> logging.log(logging.Info, "email sent to " <> to)
            Error(e) ->
              logging.log(logging.Error, "email to " <> to <> " failed: " <> e)
          }
        })
        Nil
      }
    }
  }
}
