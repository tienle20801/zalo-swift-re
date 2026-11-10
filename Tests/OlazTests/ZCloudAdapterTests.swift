import Testing
import Foundation
import JavaScriptCore
@testable import Olaz

@Suite struct ZCloudAdapterTests {
    @Test func planPublishesImmediatelyWithoutOpeningConversation() {
        let ctx = JSContext()!
        var posts: [[String: Any]] = []

        let sink: @convention(block) (JSValue) -> Void = { val in
            if let dict = val.toDictionary() as? [String: Any] {
                posts.append(dict)
            }
        }
        ctx.setObject(sink, forKeyedSubscript: "__zaloCloudTestSink" as NSString)

        ctx.evaluateScript("""
        var window = this;
        var location = { pathname: '/index.html' };
        window.__zaloCloudTestName = '__zaloCloudTest';
        window.__zaloStore = {
            getState: function() { return { user: { userId: '12345' } }; }
        };
        window.__zaloEachExport = function(req, visit) {
            for (var id in (req.c || {})) {
                var mod = req.c[id];
                if (mod && mod.exports) {
                    visit(mod.exports, id);
                }
            }
        };

        // Fake webpack runtime with modules in req.m but not yet in req.c
        var modules = {
            'qwfD': function(m, exports) {
                function UsageService() {}
                UsageService.getInstance = function() { return new UsageService(); };
                UsageService.prototype.usage = async function() {
                    return {
                        quota: 1073741824, // 1 GB
                        usage: 751619276,  // ~716.8 MB
                        family: 0,
                        plan: 0,
                        service_usage: { cloud_media: 500000000, message_backup: 251619276, my_cloud: 100000000 },
                        usageByConversation: { '12345': { total: 100000000, type: {} } },
                        usageByType: {}
                    };
                };
                UsageService.prototype.getCloudUsageByConversation = function() {};
                exports.a = UsageService;
            },
            't9fU': function(m, exports) {
                function CloudConfigv2() {}
                CloudConfigv2.getInstance = function() { return new CloudConfigv2(); };
                CloudConfigv2.prototype.isPaidUser = function() { return true; };
                CloudConfigv2.prototype.isFreev2 = function() { return false; };
                CloudConfigv2.prototype.plan = 1;
                exports.CloudConfigv2 = CloudConfigv2;
            },
            'tP1L': function(m, exports) {
                exports.a = {
                    getCloudSettings: async function() { return { opt_in: 7, enable_offload: 1, cloud_media_file_size_limit: 1073741824 }; },
                    getUsageZCloudV2: async function() { return {}; }
                };
            },
            'xn9U': function(m, exports) {
                function Pkg() {}
                Pkg.getInstance = function() { return new Pkg(); };
                Pkg.prototype.getFullPackageName = function() { return 'zCloud 100GB'; };
                Pkg.prototype.getInfo = async function() { return { subscription_info: { expire_time: 1750000000000, duration_months: 12 } }; };
                Pkg.prototype.getNameInfo = async function() { return { vi: 'zCloud 100GB' }; };
                exports.a = Pkg;
            },
            'u4F8': function(m, exports) {
                exports.zCloudPlans = { zcloud: 1, free: 0, grace_period: 2, free_after_grace_period: 3 };
                exports.CLOUD_EVENT_TYPES = {
                    USAGE_UPDATED: 'USAGE_UPDATED',
                    CHANGE_PLAN: 'CHANGE_PLAN',
                    FAMILY_INFO_UPDATED: 'FAMILY_INFO_UPDATED',
                    UPDATE_CLOUD_KEY_STATUS: 'UPDATE_CLOUD_KEY_STATUS',
                    UPDATE_INFO: 'UPDATE_INFO',
                    ADD_CLOUD_ITEMS: 'ADD_CLOUD_ITEMS',
                    REMOVE_CLOUD_ITEMS: 'REMOVE_CLOUD_ITEMS',
                    REMOVE_THREAD_CLOUD: 'REMOVE_THREAD_CLOUD'
                };
            },
            'NDmK': function(m, exports) {
                exports.default = { sendToMeId: '12345' };
            }
        };

        var cache = {};
        function req(id) {
            if (cache[id]) return cache[id].exports;
            var m = { exports: {} };
            cache[id] = m;
            if (modules[id]) {
                modules[id](m, m.exports);
            }
            return m.exports;
        }
        req.c = cache;
        req.m = modules;
        window.__zaloRequire = req;
        """)

        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Olaz/HostScripts/zcloud-adapter.js")
        let scriptSource = try! String(contentsOf: scriptURL, encoding: .utf8)
        ctx.evaluateScript(scriptSource)

        // Wait for async publish to complete
        var settled = false
        for _ in 0..<20 {
            if !posts.isEmpty && posts.contains(where: { $0["plan"] != nil }) {
                settled = true
                break
            }
            // Run microtasks
            ctx.evaluateScript("new Promise(function(r) { setTimeout(r, 50); })")
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        #expect(settled, "zcloud adapter should publish plan immediately upon resolving without waiting for chatbox")
        let planPost = posts.first(where: { $0["plan"] != nil })
        let plan = planPost?["plan"] as? [String: Any]
        #expect(plan != nil)
        #expect(plan?["quota"] as? Int == 1073741824)
        #expect(plan?["usage"] as? Int == 751619276)
        #expect(plan?["name"] as? String == "zCloud 100GB")
    }
}
