;; Build, sign and publish the placement manifest (no central store).
;;
;;   python -m hy tools/placement_plan.hy --home ~/.hermes \
;;       --node did:key:WS=http://100.108.223.94:8642:anonymous,attested \
;;       --node did:key:BJ=http://100.75.169.8:8642:anonymous \
;;       --workstation did:key:WS --canary 20 --canary-node did:key:BJ   # dry run
;;   ... --apply http://127.0.0.1:8642      # PUT /v1/placement on that gateway
;;                                          # (bearer API_SERVER_KEY from HERMES_HOME/.env)
;;
;; Every profile is pinned to the workstation except the canaries, pinned to
;; the canary node. Canaries are chosen to be safe to move first: no secrets
;; in the profile's own .env, every enabled job delivers "local", at least one
;; enabled job, and the lowest measured cost (busy seconds per day from
;; cron/executions.db). Profiles whose .env holds keys or tokens are
;; "attested", so they are never placed on an anonymous node.
;;
;; --hold FILE marks profiles no node may tick (a signed, reversible pause:
;; drop them from the file and publish again). Their jobs.json is untouched.
;;
;; The manifest is signed with the operator key (~/.kotoba/operator.key,
;; created on first use; nodes trust its did via --operator-did) and carries a
;; millisecond version, so a newer plan always supersedes an older one.

(import argparse json os re sys
        urllib.request [Request urlopen])

(setv HERE (os.path.dirname (os.path.abspath __file__))
      ROOT (os.path.dirname HERE))
(setv (cut sys.path 0 0) [(os.path.join ROOT ".deps") ROOT])

(import kotoba_gateway.shard [cost-report job-list profile-homes]
        kotoba_gateway.identity [NodeIdentity]
        kotoba_gateway.placement [build-manifest])

(setv SECRET-LINE (re.compile r"^\s*(?:export\s+)?[A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PRIVATE)[A-Z0-9_]*\s*=\s*\S" re.M)
      PROFILE-ID (re.compile r"^[a-z0-9_][a-z0-9_-]{0,63}$"))

(defn has-secrets [home]
  (try
    (with [f (open (os.path.join home ".env") :encoding "utf-8")]
      (bool (.search SECRET-LINE (.read f))))
    (except [OSError] False)))

(defn enabled-jobs [home]
  (try
    (with [f (open (os.path.join home "cron" "jobs.json") :encoding "utf-8")]
      (lfor j (job-list (json.load f)) :if (.get j "enabled" True) j))
    (except [[OSError ValueError]] [])))

(defn plan [home workstation canary-n canary-node]
  (setv full (cost-report home :nodes 1 :top None)
        costs (dfor p (get full "costliest") (get p "profile") (get p "busy_seconds_per_day"))
        profiles []
        candidates [])
  (for [[name phome] (profile-homes home)]
    (when (not (.match PROFILE-ID name)) (continue))
    (setv secret (has-secrets phome)
          jobs (enabled-jobs phome)
          local-only (and (bool jobs)
                          (all (gfor j jobs (= (str (or (.get j "deliver") "local")) "local"))))
          record {"id" name "residency" (if secret "attested" "anonymous")
                  "pin" workstation "caps" ["python3"]})
    (when (in name costs) (setv (get record "cost") (get costs name)))
    (.append profiles record)
    (when (and (!= name "default") (not secret) local-only)
      (.append candidates #((.get costs name 0.0) name))))
  (.sort candidates)
  (setv canaries (if canary-node (lfor [_cost name] (cut candidates canary-n) name) []))
  (for [record profiles]
    (when (in (get record "id") canaries)
      (setv (get record "pin") canary-node)))
  {"profiles" profiles "canaries" canaries
   "summary" {"profiles" (len profiles)
              "attested" (sum (gfor p profiles (int (= (get p "residency") "attested"))))
              "canary_candidates" (len candidates)
              "canaries" (len canaries)
              "history_profiles" (get full "profiles_with_history")}})

(defn read-ids [path]
  (if (not path)
      #{}
      (with [f (open path :encoding "utf-8")]
        (sfor line f :setv id (.strip line) :if (and id (not (.startswith id "#"))) id))))

(defn apply-holds [profiles ids reason]
  "Mark the records whose id is in ids as held. Returns how many were."
  (setv n 0)
  (for [record profiles]
    (when (in (get record "id") ids)
      (setv (get record "hold") reason)
      (+= n 1)))
  n)

(defn parse-node [spec]
  "did=url:residency1,residency2 -> manifest node entry."
  (setv [did rest] (.split spec "=" 1))
  (if (> (.count rest ":") 2)
      (setv [url _ residency] (.rpartition rest ":"))
      (setv url rest residency ""))
  {"did" did "url" url
   "residency" (or (lfor r (.split residency ",") :if r r) ["anonymous"])
   "caps" ["python3"]})

(defn api-key [home]
  (setv key (os.environ.get "API_SERVER_KEY"))
  (when key (return key))
  (try
    (with [f (open (os.path.join home ".env") :encoding "utf-8")]
      (for [line f]
        (when (.startswith (.strip line) "API_SERVER_KEY=")
          (return (.strip (.strip (get (.split line "=" 1) 1)) "'\"")))))
    (except [OSError]))
  (raise (SystemExit "API_SERVER_KEY not found (env or HERMES_HOME/.env)")))

(defn publish [gateway home manifest]
  (setv req (Request (+ (.rstrip gateway "/") "/v1/placement") :method "PUT"
                     :data (.encode (json.dumps manifest))
                     :headers {"authorization" f"Bearer {(api-key home)}"
                               "content-type" "application/json"}))
  (with [res (urlopen req :timeout 30)]
    (json.loads (.read res))))

(defn main [[argv None]]
  (setv p (argparse.ArgumentParser :description "Build, sign and publish the placement manifest."))
  (.add_argument p "--home" :default (os.path.expanduser (os.environ.get "HERMES_HOME" "~/.hermes")))
  (.add_argument p "--node" :action "append" :default [] :required True
                 :help "did=url:residency[,residency] (repeatable)")
  (.add_argument p "--workstation" :required True :help "did:key every non-canary profile is pinned to")
  (.add_argument p "--canary" :type int :default 20)
  (.add_argument p "--canary-node" :help "did:key of the canary node (omit: no canaries)")
  (.add_argument p "--operator-key" :default (os.path.expanduser "~/.kotoba/operator.key"))
  (.add_argument p "--hold" :metavar "FILE"
                 :help "profile ids (one per line) no node may tick; jobs.json is untouched")
  (.add_argument p "--hold-reason" :default "held by operator")
  (.add_argument p "--write" :help "also write the signed manifest to this path")
  (.add_argument p "--apply" :metavar "GATEWAY_URL" :help "PUT the manifest to this gateway")
  (.add_argument p "--json" :action "store_true" :help "print the full manifest")
  (setv a (.parse_args p argv)
        operator (NodeIdentity.load-or-create a.operator-key)
        result (plan a.home a.workstation a.canary a.canary-node)
        held (apply-holds (get result "profiles") (read-ids a.hold) a.hold-reason)
        manifest (build-manifest operator (lfor n a.node (parse-node n)) (get result "profiles")))
  (setv (get result "summary" "held") held)
  (if a.json
      (print (json.dumps manifest :indent 2))
      (do (print (json.dumps {#** (get result "summary")
                              "operator" operator.did "version" (get manifest "version")}))
          (for [name (get result "canaries")] (print "canary" name))))
  (when a.write
    (with [f (open a.write "w" :encoding "utf-8")] (json.dump manifest f)))
  (when a.apply
    (print (publish a.apply a.home manifest)))
  0)

(when (= __name__ "__main__")
  (sys.exit (main)))
