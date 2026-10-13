;; Contract tests for the Hermes API surface, run against the echo backend
;; over real HTTP so the wire shapes the desktop parses are what we assert.

(import json os shlex sys tempfile threading unittest
        urllib.request [Request urlopen]
        urllib.error [HTTPError]
        unittest.mock [patch])
(import kotoba_gateway.backend [Callbacks EchoBackend KotobaBackend]
        kotoba_gateway.server [make-server split-chat-messages])

(setv KEY "test-key-0123456789abcdef")

(defn sse-events [raw]
  (lfor block (.split raw "\n\n")
        :setv data (lfor line (.split block "\n") :if (.startswith line "data: ") (cut line 6 None))
        :if data
        (.join "\n" data)))

(defclass GatewayContract [unittest.TestCase]
  (defn [classmethod] setUpClass [cls]
    (setv cls.state (tempfile.TemporaryDirectory)
          [cls.server _] (make-server "127.0.0.1" 0 (EchoBackend) KEY :state-dir cls.state.name)
          cls.base f"http://127.0.0.1:{(get cls.server.server_address 1)}")
    (.start (threading.Thread :target cls.server.serve_forever :daemon True)))

  (defn [classmethod] tearDownClass [cls]
    (.shutdown cls.server)
    (.server_close cls.server)
    (.cleanup cls.state))

  (defn call [self method path [body None] [key KEY] [headers None]]
    (setv req (Request (+ self.base path) :method method
                       :data (when (is-not body None) (.encode (json.dumps body)))))
    (.add_header req "Content-Type" "application/json")
    (when key (.add_header req "Authorization" (+ "Bearer " key)))
    (for [[k v] (.items (or headers {}))] (.add_header req k v))
    (with [res (urlopen req :timeout 10)]
      [res.status (dict res.headers) (.decode (.read res) "utf-8")]))

  ;; @lat: [[gateway-hy#Tests#Health is unauthenticated]]
  (defn test-health-is-unauthenticated [self]
    (setv [status _ body] (.call self "GET" "/health" :key None))
    (.assertEqual self status 200)
    (.assertEqual self (get (json.loads body) "platform") "hermes-agent"))

  ;; @lat: [[gateway-hy#Tests#Bearer auth is enforced]]
  (defn test-bearer-auth-is-enforced [self]
    (with [ctx (.assertRaises self HTTPError)]
      (.call self "GET" "/v1/models" :key "wrong"))
    (.assertEqual self ctx.exception.code 401))

  ;; @lat: [[gateway-hy#Tests#Capabilities advertise runs]]
  (defn test-capabilities-advertise-runs [self]
    (setv caps (json.loads (get (.call self "GET" "/p/work/v1/capabilities") 2)))
    (.assertTrue self (get caps "features" "run_submission"))
    (.assertEqual self (get caps "endpoints" "run_events" "path") "/v1/runs/{run_id}/events"))

  ;; @lat: [[gateway-hy#Tests#Runs stream message deltas then completion]]
  (defn test-runs-stream-deltas-then-completion [self]
    (setv [status _ body] (.call self "POST" "/v1/runs" {"input" "hello kotoba"
                                                        "session_id" "desk-1"}))
    (.assertEqual self status 202)
    (setv started (json.loads body)
          raw (get (.call self "GET" (+ "/v1/runs/" (get started "run_id") "/events")) 2)
          events (lfor d (sse-events raw) (json.loads d))
          names (lfor e events (get e "event")))
    (.assertEqual self (get started "session_id") "desk-1")
    (.assertIn self "tool.started" names)
    (.assertIn self "message.delta" names)
    (.assertEqual self (get names -1) "run.completed")
    (.assertEqual self (get events -1 "output") "echo: hello kotoba")
    (.assertEqual self (.join "" (lfor e events :if (= (get e "event") "message.delta") (get e "delta")))
                  "echo: hello kotoba "))

  ;; @lat: [[gateway-hy#Tests#Chat completions stream OpenAI chunks]]
  (defn test-chat-completions-stream [self]
    (setv [status headers raw]
          (.call self "POST" "/v1/chat/completions"
                 {"model" "hermes-agent" "stream" True
                  "messages" [{"role" "system" "content" "be brief"}
                              {"role" "user" "content" "earlier"}
                              {"role" "assistant" "content" "ok"}
                              {"role" "user" "content" "hi"}]}
                 :headers {"X-Hermes-Session-Id" "desk-2"})
          data (sse-events raw))
    (.assertEqual self status 200)
    (.assertEqual self (.get headers "X-Hermes-Session-Id") "desk-2")
    (.assertEqual self (get data -1) "[DONE]")
    (setv text (.join "" (lfor d (cut data -1)
                               :setv c (json.loads d)
                               :if (in "choices" c)
                               (or (.get (get c "choices" 0 "delta") "content") ""))))
    (.assertEqual self (.strip text) "echo: hi"))

  ;; @lat: [[gateway-hy#Tests#Chat completions without streaming]]
  (defn test-chat-completions-blocking [self]
    (setv body (json.loads (get (.call self "POST" "/v1/chat/completions"
                                       {"messages" [{"role" "user" "content" "yo"}]}) 2)))
    (.assertEqual self (get body "choices" 0 "message" "content") "echo: yo"))

  ;; @lat: [[gateway-hy#Tests#Unknown runs are 404]]
  (defn test-unknown-run-is-404 [self]
    (with [ctx (.assertRaises self HTTPError)]
      (.call self "POST" "/v1/runs/run_missing/stop" {}))
    (.assertEqual self ctx.exception.code 404))

  ;; @lat: [[gateway-hy#Tests#Message splitting]]
  (defn test-split-chat-messages [self]
    (setv [instructions history user] (split-chat-messages
                                        [{"role" "system" "content" "s"}
                                         {"role" "user" "content" [{"type" "text" "text" "a"}]}
                                         {"role" "assistant" "content" "b"}
                                         {"role" "user" "content" "c"}]))
    (.assertEqual self instructions "s")
    (.assertEqual self history [{"role" "user" "content" "a"} {"role" "assistant" "content" "b"}])
    (.assertEqual self user "c")
    (.assertEqual self (get (split-chat-messages [{"role" "assistant" "content" "x"}]) 2) None))


  (defn test-kotoba-backend-approval-bridge [self]
    (with [state (tempfile.TemporaryDirectory)]
      (setv bridge (os.path.join state "fake_bridge.py"))
      (with [f (open bridge "w" :encoding "utf-8")]
        (.write f (.join "" ["import json, sys\n"
                       "request=json.loads(sys.stdin.readline())\n"
                       "print(json.dumps({'type':'approval.request','approval_id':'a-1','tool':'write_file','arguments':'{}','description':'Allow write?'}), flush=True)\n"
                       "approval=json.loads(sys.stdin.readline())\n"
                       "assert approval['type']=='approval' and approval['approval_id']=='a-1' and approval['approved'] is True\n"
                       "print(json.dumps({'type':'event','event':{'event':'assistant','content':'done','tool-calls':0}}), flush=True)\n"
                       "print(json.dumps({'type':'result','result':{'final_response':'done','completed':True,'usage':{'input_tokens':1,'output_tokens':1,'total_tokens':2},'model':'test-model','provider':'test-provider'}}), flush=True)\n"])))
      (with [env (patch.dict os.environ
                            {"ITONAMI_AGENT_COMMAND" (+ (shlex.quote sys.executable) " " (shlex.quote bridge))
                             "ITONAMI_AGENT_TOOL_NAMES" "read_file"})]
        (let [agent []
              deltas []
              cb (Callbacks :on_agent (fn [a] (.append agent a))
                            :on_delta (fn [d] (.append deltas d))
                            :on_approval (fn [a] (.approve (get agent 0) (.get a "approval_id") True)))
              result (.run-turn (KotobaBackend) :callbacks cb :user_message "hello"
                                :history [] :instructions "" :model "hermes-agent")]
          (.assertTrue self (.get result "completed"))
          (.assertEqual self (.get result "final_response") "done")
          (.assertEqual self (get result "usage" "total_tokens") 2)
          (.assertEqual self deltas ["done"]))))))

(when (= __name__ "__main__")
  (unittest.main))
