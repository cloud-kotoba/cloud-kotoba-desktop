;; Fleet secrets through kagi: a profile's secrets reach only the node that
;; runs it, without a central store and without plaintext files on that node.
;;
;; Owner side (the workstation holds the kagi vault):
;;   - each profile's .env becomes the kagi item `hermes-env.<profile>`, and
;;     the env every profile shares (provider keys) becomes `hermes-env.fleet`,
;;     both in compartment `hermes-fleet`;
;;   - each node is a kagi agent principal (its own key, approved by
;;     fingerprint). The owner grants a node exactly the items of the
;;     profiles placement gives it, and ungrants (re-keys) on a move;
;;   - the vault file is ciphertext, so it is copied to every node as is.
;;
;; Node side: upstream Hermes' `command` secret source runs a helper once per
;; profile home and keeps the KEY=VALUE map it prints in that profile's secret
;; scope (never os.environ, never disk). `tools/kagi_env.hy` is that helper:
;; it opens the granted items from the node's vault copy with the node's own
;; agent key (`kagi agent get`, offline, audited in the node's own chain).

(import json os subprocess)

(setv COMPARTMENT "hermes-fleet"
      FLEET-ITEM "hermes-env.fleet"
      ITEM-PREFIX "hermes-env."
      ;; The helper starts a JVM per item (~3 s each on an M-series Mac).
      HELPER-TIMEOUT-SECONDS 120
      NODE-CONFIG "~/.kagi-agent/node.json")

(defn item-name [profile]
  (+ ITEM-PREFIX profile))

(defn profile-of-home [hermes-home]
  "The profile a HERMES_HOME belongs to: `<root>/profiles/<name>` -> name,
  anything else (the root home) -> \"default\"."
  (setv path (os.path.normpath hermes-home)
        parent (os.path.dirname path))
  (if (= (os.path.basename parent) "profiles")
      (os.path.basename path)
      "default"))

(defn parse-env [text]
  "KEY=VALUE lines -> dict (comments, blanks and `export ` skipped; later wins)."
  (setv out {})
  (for [line (.splitlines (or text ""))]
    (setv line (.strip line))
    (when (.startswith line "export ")
      (setv line (.strip (cut line 7 None))))
    (when (and line (not (.startswith line "#")) (in "=" line))
      (setv [k v] (.split line "=" 1)
            k (.strip k))
      (when (and k (.isidentifier k))
        (setv (get out k) (.strip v)))))
  out)

(defn render-env [mapping]
  (.join "" (gfor [k v] (.items mapping) f"{k}={v}\n")))

(defn merge-envs [texts]
  "Fleet env first, then the profile's: a profile value overrides the fleet's."
  (setv out {})
  (for [t texts] (.update out (parse-env t)))
  out)

;; ─── node side: open items with the node's agent key ─────────────────────

(defn load-node-config [[path None]]
  "{kagi_bin kagi_home identity_ref agent_id [path]} written when the node was enrolled."
  (with [f (open (os.path.expanduser (or path NODE-CONFIG)) :encoding "utf-8")]
    (json.load f)))

(defn is-absent [stdout]
  "`kagi agent get` prints an EDN status map instead of a value when the item
  is missing or not granted to this agent."
  (.startswith (.lstrip stdout) "{:status"))

(defn kagi-get [cfg item purpose [run subprocess.run]]
  "The item's plaintext, or None when it is absent/not granted. Raises on any
  other failure, so the helper exits non-zero and upstream retries later."
  (setv env {"HOME" (os.path.expanduser "~")
             "PATH" (.get cfg "path" "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
             "KAGI_HOME" (os.path.expanduser (get cfg "kagi_home"))
             "KAGI_IDENTITY_REF" (get cfg "identity_ref")
             "KAGI_AGENT_ID" (get cfg "agent_id")}
        r (run [(os.path.expanduser (get cfg "kagi_bin")) "agent" "get" item "--purpose" purpose]
               :env env :capture_output True :text True :timeout HELPER-TIMEOUT-SECONDS))
  (cond
    (is-absent r.stdout) None
    ;; an item that was never put (e.g. a profile with no secrets)
    (in "no such item" (.lower (+ (or r.stdout "") (or r.stderr "")))) None
    (!= r.returncode 0) (raise (RuntimeError f"kagi agent get {item} exited {r.returncode}"))
    True r.stdout))

(defn profile-env [cfg hermes-home [run subprocess.run]]
  "The merged KEY=VALUE map the node may give this profile."
  (setv profile (profile-of-home hermes-home)
        purpose f"hermes-cron:{profile}"
        texts (lfor item [FLEET-ITEM (item-name profile)]
                    :setv text (kagi-get cfg item purpose :run run)
                    :if (is-not text None)
                    text))
  (merge-envs texts))

;; ─── owner side: what a staged profile's config.yaml gets ────────────────

(defn secrets-command-block [python gateway-dir]
  "The `secrets.command` config upstream reads per profile home."
  {"enabled" True
   "command" (+ f"PYTHONPATH={gateway-dir}/.deps:{gateway-dir} "
                f"{python} -m hy {gateway-dir}/tools/kagi_env.hy")
   "helper_timeout_seconds" HELPER-TIMEOUT-SECONDS})

(defn with-secrets-command [config block]
  "config (a parsed config.yaml dict) with secrets.command set to block,
  other secrets sources untouched."
  (setv config (dict (or config {}))
        secrets (dict (or (.get config "secrets") {})))
  (setv (get secrets "command") block
        (get config "secrets") secrets)
  config)
