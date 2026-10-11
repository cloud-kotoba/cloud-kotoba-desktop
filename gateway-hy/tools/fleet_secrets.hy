;; Owner-side fleet secrets: put profile envs into kagi, grant them to the node
;; that runs the profile, copy the (ciphertext) vault to nodes, and stage a
;; profile on a node with the kagi helper wired into its config.yaml.
;;
;;   python -m hy tools/fleet_secrets.hy put PROFILE...          # .env -> hermes-env.PROFILE
;;   python -m hy tools/fleet_secrets.hy put-fleet KEY...        # ~/.hermes/.env keys -> hermes-env.fleet
;;   python -m hy tools/fleet_secrets.hy grant AGENT-ID ITEM...  # (ungrant: re-keys the item)
;;   python -m hy tools/fleet_secrets.hy replicate HOST...       # vault.edn + agent registry -> node
;;   python -m hy tools/fleet_secrets.hy node-config HOST AGENT-ID
;;   python -m hy tools/fleet_secrets.hy stage HOST PROFILE...   # copy profile (no .env), add helper
;;
;; KAGI_BIN (default ~/github/kotoba-lang/kagi/bin/kagi) is the owner's kagi;
;; KAGI_HOME defaults to ~/.kagi. Values only ever travel on stdin.

(import json os shlex subprocess sys tempfile)

(setv HERE (os.path.dirname (os.path.abspath __file__))
      ROOT (os.path.dirname HERE))
(setv (cut sys.path 0 0) [(os.path.join ROOT ".deps") ROOT])

(import yaml
        kotoba_gateway.fleet_secrets [COMPARTMENT FLEET-ITEM item-name parse-env render-env
                                      secrets-command-block with-secrets-command])

(setv HERMES-HOME (os.path.expanduser (os.environ.get "HERMES_HOME" "~/.hermes"))
      KAGI-HOME (os.path.expanduser (os.environ.get "KAGI_HOME" "~/.kagi"))
      KAGI-BIN (os.path.expanduser (os.environ.get "KAGI_BIN" "~/github/kotoba-lang/kagi/bin/kagi"))
      SSH ["ssh" "-o" "BatchMode=yes"])

(defn kagi [args [stdin None]]
  (setv r (subprocess.run [KAGI-BIN #* args] :input stdin :capture_output True :text True
                          :env {#** os.environ "KAGI_HOME" KAGI-HOME}))
  (when (!= r.returncode 0)
    (setv why (get (+ ["?"] (.splitlines r.stderr)) -1))
    (raise (SystemExit f"kagi {(get args 0)} failed ({r.returncode}): {why}")))
  (.strip (get (+ [""] (.splitlines r.stdout)) -1)))

(defn read-text [path]
  (try (with [f (open path :encoding "utf-8")] (.read f))
       (except [OSError] "")))

(defn put [profiles]
  (for [p profiles]
    (setv env (parse-env (read-text (os.path.join HERMES-HOME "profiles" p ".env"))))
    (if env
        (print p (kagi ["add" (item-name p) "-c" COMPARTMENT] :stdin (render-env env)))
        (print p "no .env values; nothing stored"))))

(defn put-fleet [keys]
  (setv root (parse-env (read-text (os.path.join HERMES-HOME ".env")))
        missing (lfor k keys :if (not-in k root) k))
  (when missing (raise (SystemExit f"not in {HERMES-HOME}/.env: {missing}")))
  (print (kagi ["add" FLEET-ITEM "-c" COMPARTMENT]
               :stdin (render-env (dfor k keys k (get root k))))))

(defn grant [verb agent items]
  (for [item items] (print (kagi ["agent" verb agent item]))))

(defn run [argv [stdin None]]
  (setv r (subprocess.run argv :input stdin :capture_output True :text True))
  (when (!= r.returncode 0)
    (raise (SystemExit f"{(shlex.join (cut argv 0 4))} failed: {(.strip r.stderr)}")))
  r.stdout)

(defn remote [host script]
  (run [#* SSH host script]))

(defn replicate [hosts]
  (for [h hosts]
    (remote h "mkdir -p ~/.kagi-agent/agents && chmod 700 ~/.kagi-agent")
    (for [rel ["vault.edn" "agents/registry.edn"]]
      (run ["scp" "-q" (os.path.join KAGI-HOME rel) f"{h}:.kagi-agent/{rel}.new"])
      (remote h f"chmod 600 ~/.kagi-agent/{rel}.new && mv ~/.kagi-agent/{rel}.new ~/.kagi-agent/{rel}"))
    (print h "vault replicated")))

(defn node-config [host agent]
  (setv home (.strip (remote host "echo $HOME"))
        cfg {"kagi_bin" f"{home}/github/kotoba-lang/kagi/bin/kagi"
             "kagi_home" f"{home}/.kagi-agent"
             "identity_ref" f"file://{home}/.kagi-agent/identity.secret"
             "agent_id" agent
             "path" "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"})
  (run [#* SSH host "umask 077; cat > ~/.kagi-agent/node.json"] :stdin (json.dumps cfg :indent 2))
  (print host "node.json written"))

(defn stage [host profiles]
  "Copy each profile to the node without its .env, with secrets.command set."
  (setv home (.strip (remote host "echo $HOME"))
        python (.strip (remote host "ls -d ~/.hermes/tools/python-*/bin/python3 | head -1"))
        block (secrets-command-block python f"{home}/.kotoba/gateway-hy"))
  (for [p profiles]
    (setv src (os.path.join HERMES-HOME "profiles" p))
    (run ["rsync" "-a" "--stats" "--exclude" ".env" "--exclude" "*.lock" "--exclude" "auth.lock"
          (+ src "/") f"{host}:.hermes/profiles/{p}/"])
    (with [f (open (os.path.join src "config.yaml") :encoding "utf-8")]
      (setv cfg (with-secrets-command (yaml.safe_load f) block)))
    (run [#* SSH host f"cat > ~/.hermes/profiles/{(shlex.quote p)}/config.yaml"]
         :stdin (yaml.safe_dump cfg :sort_keys False :allow_unicode True))
    (print host p "staged")))

(defn main [[argv None]]
  (setv argv (or argv (cut sys.argv 1 None)))
  (when (not argv) (raise (SystemExit "usage: fleet_secrets.hy put|put-fleet|grant|ungrant|replicate|node-config|stage ...")))
  (setv [cmd #* args] argv)
  (cond (= cmd "put") (put args)
        (= cmd "put-fleet") (put-fleet args)
        (in cmd #{"grant" "ungrant"}) (grant cmd (get args 0) (cut args 1 None))
        (= cmd "replicate") (replicate args)
        (= cmd "node-config") (node-config (get args 0) (get args 1))
        (= cmd "stage") (stage (get args 0) (cut args 1 None))
        True (raise (SystemExit f"unknown command {cmd}")))
  0)

(when (= __name__ "__main__")
  (sys.exit (main)))
