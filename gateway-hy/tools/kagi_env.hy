;; Upstream Hermes `secrets.command` helper on a fleet node.
;;
;; Hermes runs this once per profile home (via /bin/sh -c, HERMES_HOME set to
;; that home) and keeps the KEY=VALUE map it prints in the profile's secret
;; scope. It prints the fleet env plus this profile's env, opened from the
;; node's kagi vault copy with the node's own agent key. A failure exits
;; non-zero with no output, so upstream records the source as failed and
;; retries; stderr carries only the item name, never a value.

(import os sys)

(setv HERE (os.path.dirname (os.path.abspath __file__))
      ROOT (os.path.dirname HERE))
(setv (cut sys.path 0 0) [(os.path.join ROOT ".deps") ROOT])

(import kotoba_gateway.fleet_secrets [load-node-config profile-env render-env])

(defn main []
  (setv home (os.environ.get "HERMES_HOME"))
  (when (not home)
    (print "kagi_env: HERMES_HOME is not set" :file sys.stderr)
    (return 2))
  (try
    (sys.stdout.write (render-env (profile-env (load-node-config) home)))
    0
    (except [e Exception]
      (print f"kagi_env: {(. (type e) __name__)}: {e}" :file sys.stderr)
      1)))

(when (= __name__ "__main__")
  (sys.exit (main)))
