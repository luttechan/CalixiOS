const fs = require("node:fs");
const path = require("node:path");
const assert = require("node:assert/strict");
const { test } = require("node:test");

const origin = "https://canvas.bufs.ac.kr";
const script = fs.readFileSync(path.join(__dirname, "../Calix/CanvasSync.js"), "utf8");
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const sync = new AsyncFunction("expectedOwner", "includeAttendance", "location", "document", "fetch", "knownModules", "window", script);
const root = "/learningx/api/v1/courses/42";
const fixtures = new Map([
    ["/api/v1/users/self/profile", { id: 13 }],
    ["/api/v1/courses", [{ id: 42, name: "Algorithms" }]],
    ["/api/v1/planner/items", []],
    ["/api/v1/calendar_events", []],
    ["/api/v1/courses/42/assignments", [{
        id: 4, name: "Project", due_at: "2026-11-20T23:59:00+09:00", html_url: "https://outside.invalid/",
        submission: { workflow_state: "graded", submission_comments: [{ comment: "Good" }] },
    }]],
    ["/api/v1/courses/42/students/submissions", [{
        assignment_id: 4, user_id: 13, workflow_state: "graded", submission_comments: [{ comment: "Good" }],
        rubric_assessment: { clarity: { comments: "Clear reasoning" } },
    }]],
    [root + "/modules", { modules: [{ items: [{
        title: "Lecture", module_item_id: 8, completed: true,
        content_data: { item_content_type: "readystream", due_at: "2026-11-20T14:59:00Z" },
    }] }] }],
    [root + "/lessons", [{ week_position: 2, lessons: [{ lesson_position: 1, class_date: "2026-11-20" }] }]],
    [root + "/lessons/attendances", [{ week_position: 2, lesson_position: 1, attendance_status: "excused" }]],
    [root + "/attendance_items", { attendance_items: [{ item_id: 8, title: "Lecture" }] }],
    [root + "/attendance_items/summary", { attendance_summaries: { 8: { attendance_status: "attendance" } } }],
]);

function transport({ fail, carryNext = false, deep = false, unchanged = false, overrides = {} } = {}) {
    return async (url, settings) => {
        assert.equal(url.origin, origin);
        assert.equal(settings.credentials, "same-origin");
        assert.equal(settings.redirect, "error");
        if (url.pathname.startsWith(root)) assert.equal(settings.headers.Authorization, "Bearer fixture-token");
        if (fail === url.pathname) throw Error("offline");
        assert.ok(fixtures.has(url.pathname), `unexpected path ${url.pathname}`);
        const page = url.searchParams.get("page");
        let payload = page === "2" ? [] : (overrides[url.pathname] ?? fixtures.get(url.pathname));
        const headers = new Headers();
        if (url.pathname === root + "/modules") {
            headers.set("ETag", '"modules-version-1"');
            if (unchanged) {
                assert.equal(settings.headers["If-None-Match"], '"modules-version-1"');
                return { status: 304, ok: false, headers };
            }
            if (deep) {
                for (let level = 0; level < 16; ++level) payload = { children: [payload] };
                payload = { modules: [payload] };
            }
        }
        if (carryNext && url.pathname === "/api/v1/courses" && !page) {
            headers.set("Link", `<${origin}/api/v1/courses?page=2>; rel="next"`);
        }
        return { ok: true, headers, text: async () => "while(1);" + JSON.stringify(payload) };
    };
}

const run = (owner, attendance, fetch, validators, window, document = { cookie: "xn_api_token=fixture-token" }) =>
    sync(owner, attendance, { origin }, document, fetch, validators, window).then(JSON.parse);

test("projects paginated assignments, LearningX video, and explicit attendance states", async () => {
    const value = await run("13", true, transport({ carryNext: true }));
    assert.equal(value.owner, "13");
    const [course] = value.courses;
    assert.equal(course.assignments[0].done, true);
    assert.match(course.assignments[0].feedback, /Good/);
    assert.match(course.assignments[0].feedback, /Clear reasoning/);
    assert.equal(course.assignments[0].url, origin + "/courses/42/assignments/4");
    assert.equal(course.assignments[0].due, "2026-11-20T14:59:00.000Z");
    assert.equal(course.videos[0].done, true);
    assert.deepEqual(course.attendance.map((row) => row.status), ["excused", "attendance"]);
    assert.doesNotMatch(JSON.stringify(value), /fixture-token/);
});

test("marks partial lists unavailable while preserving successfully fetched data", async () => {
    const [course] = (await run("", false, transport({ fail: root + "/modules" }))).courses;
    assert.equal(course.videos, null);
    assert.equal(course.attendance, null);
    assert.equal(course.assignments.length, 1);
});

test("rejects switching accounts or executing outside the school origin", async () => {
    await assert.rejects(run("99", true, transport()), /ACCOUNT_CHANGED/);
    await assert.rejects(sync("", false, { origin: "https://outside.invalid" }, {}, transport()), /AUTH_REQUIRED/);
});

test("extracts deeply nested videos and keeps cached modules on 304", async () => {
    const [initial] = (await run("13", false, transport({ deep: true }))).courses;
    assert.equal(initial.videos.length, 1);
    assert.equal(initial.modulesValidator, '"modules-version-1"');
    const [cached] = (await run("13", false, transport({ unchanged: true }), { 42: initial.modulesValidator })).courses;
    assert.equal(cached.videos, null);
    assert.equal(cached.modulesUnchanged, true);
    assert.equal(cached.modulesVerified, true);
    assert.equal(cached.assignments[0].status, "graded");
});

test("keeps available native Canvas modules when LearningX fails", async () => {
    const window = {
        [Symbol.for("calix.canvas.modules")]: {
            collect: async (course) => {
                assert.equal(course, 42);
                return { complete: false, items: [{ id: 91, title: "Module media", completed: null,
                    url: origin + "/courses/42/modules/items/91", content_details: {} }] };
            },
        },
    };
    const [course] = (await run("13", false, transport({ fail: root + "/modules" }), {}, window)).courses;
    assert.equal(course.modulesPartial, true);
    assert.equal(course.videos[0].id, "canvas:42:video:91");
    assert.equal(course.videos[0].status, "unverified");
});

test("reads the student's submission deadline and nested LearningX periods", async () => {
    const overrides = {
        "/api/v1/courses/42/assignments": [{ id: 4, name: "Project", due_at: null }],
        "/api/v1/courses/42/students/submissions": [{ assignment_id: 4, user_id: 13, cached_due_date: "2026-11-20T22:30:00+09:00" }],
        [root + "/modules"]: { modules: [{ items: [{ title: "Lecture", module_item_id: 8, due_at: "invalid",
            content_data: { item_content_data: { content_type: "movie", lecture_periods: [
                { due_at: "2026-11-22 21:15:00" }, { due_at: "2026-11-23 23:59:00" },
            ] } } }] }] },
    };
    const [course] = (await run("13", false, transport({ overrides }))).courses;
    assert.equal(course.assignments[0].due, "2026-11-20T13:30:00.000Z");
    assert.equal(course.videos[0].due, "2026-11-23T14:59:00.000Z");
});

test("uses the LearningX item ID to recover video dates while attendance stays off", async () => {
    const modules = root + "/modules";
    const details = root + "/attendance_items";
    const overrides = {
        [modules]: [{ module_items: [
            { title: "Lecture", module_item_id: 71, content_id: 9001, content_data: { item_id: 9001, item_content_type: "movie", due_at: null } },
            { title: "No deadline", module_item_id: 72, content_id: 9002, content_data: { item_id: 9002, item_content_type: "movie" } },
        ] }],
        [details]: { attendance_items: [
            { item_id: 71, due_at: "2026-11-05T14:59:00Z" },
            { item_id: 9001, due_at: "2026-11-21T14:59:00Z" },
        ] },
    };
    const called = [];
    const fetch = transport({ overrides });
    const [course] = (await run("13", false, (url, request) => {
        called.push(url.pathname);
        return fetch(url, request);
    })).courses;
    assert.equal(course.videos.find(row => row.id.endsWith(":71")).due, "2026-11-21T14:59:00.000Z");
    assert.equal(course.videos.find(row => row.id.endsWith(":72")).due, null);
    assert.equal(course.attendance, null);
    assert.equal(course.modulesValidator, null);
    assert.deepEqual(called.filter(path => path.includes("/attendance")), [details]);
});

test("reads only the owner's submission with embedded assignment when assignment lists fail", async () => {
    const submissions = "/api/v1/courses/42/students/submissions";
    const dates = [
        { assignment_id: 4, user_id: 13, cached_due_date: "2026-11-21T14:59:00Z" },
        { assignment_id: 7, user_id: 14, cached_due_date: "2026-11-22T14:59:00Z" },
    ];
    const fetch = (url, request) => {
        if (url.pathname.endsWith("/assignments") || url.pathname.endsWith("/assignment_groups")) throw Error("offline");
        const overrides = url.pathname === submissions ? { [submissions]: url.searchParams.getAll("include[]").includes("assignment")
            ? dates.map(row => ({ ...row, assignment: { id: row.assignment_id, name: "Recovered", due_at: "2026-11-20T14:59:00Z" } }))
            : dates } : {};
        return transport({ overrides })(url, request);
    };
    const [course] = (await run("13", false, fetch)).courses;
    assert.deepEqual(course.assignments.map(row => [row.id, row.due]), [["canvas:42:assignment:4", "2026-11-21T14:59:00.000Z"]]);
});

test("recovers Canvas due dates from the signed-in student's planner", async () => {
    const planner = "/api/v1/planner/items";
    const rows = [
        { course_id: 42, plannable_id: 4, plannable_type: "assignment", plannable_date: "2026-11-29T14:59:00Z",
            plannable: { id: 4, title: "Project", due_at: "2026-11-29T14:59:00Z" } },
        { course_id: 43, plannable_id: 8, plannable_type: "assignment",
            plannable: { id: 8, title: "Other course", due_at: "2026-11-29T14:59:00Z" } },
        { course_id: 42, plannable_id: 9, plannable_type: "planner_note",
            plannable: { id: 9, title: "Personal note", due_at: "2026-11-29T14:59:00Z" } },
    ];
    const overrides = { [planner]: rows, "/api/v1/courses/42/assignments": [{ id: 4, name: "Project", due_at: null }] };
    const fetch = transport({ overrides });
    const [course] = (await run("13", false, (url, settings) => {
        if (url.pathname === planner) {
            assert.match(url.searchParams.get("start_date"), /^\d{4}-\d{2}-\d{2}$/);
            assert.match(url.searchParams.get("end_date"), /^\d{4}-\d{2}-\d{2}$/);
            assert.equal(url.searchParams.has("observed_user_id"), false);
        }
        return fetch(url, settings);
    })).courses;
    assert.deepEqual(course.assignments.map(row => [row.id, row.due]), [
        ["canvas:42:assignment:4", "2026-11-29T14:59:00.000Z"],
    ]);
});

test("starts LearningX with the verified course tool and retries the video API", async () => {
    let inserted = false, removed = false, calls = 0;
    const tool = origin + "/courses/42/external_tools/9";
    const anchor = { textContent: "Lecture", getAttribute: () => "/courses/42/modules/items/71" };
    const item = { querySelector: selector => selector.includes("icon") ? { classList: ["movie"] }
        : selector.includes("left-title") ? anchor : selector.includes("due_at") ? { textContent: "11월 29일 오후 11:59" } : null };
    const page = {
        getAttribute: key => ({"data-canvas_course_id": "42", "data-user_id": "13", "data-term": "2026학년도 2학기"})[key],
        querySelectorAll: selector => selector === ".xnmb-module_item-wrapper" ? [item] : [],
    };
    const frame = { style: {}, setAttribute() {}, remove: () => { removed = true; },
        contentDocument: { URL: origin + "/learningx/lti/modulebuilder", querySelector: () => page, querySelectorAll: () => [] } };
    const document = { get cookie() { return inserted ? "xn_api_token=fixture-token" : ""; },
        createElement: () => frame, documentElement: { appendChild: value => {
            assert.equal(value.src, tool);
            inserted = true;
        } } };
    const window = { [Symbol.for("calix.canvas.modules")]: {
        collect: async () => ({ items: [], complete: false, learningx: { present: true, url: tool } }),
    } };
    const modules = root + "/modules";
    const fetch = transport({ overrides: { [modules]: [{ module_items: [
        { title: "Lecture", module_item_id: 71, content_data: {item_id: 91, item_content_type: "movie", due_at: "2026-11-30T14:59:00Z"} },
    ] }] } });
    const [course] = (await run("13", false, (url, settings) => {
        if (url.pathname === modules) {
            calls++;
            if (!inserted) return { status: 403, ok: false };
        }
        return fetch(url, settings);
    }, {}, window, document)).courses;
    assert.equal(calls, 2);
    assert.equal(removed, true);
    assert.equal(course.videos[0].due, "2026-11-30T14:59:00.000Z");
});

test("retains an assignment from the first page and recovers missing assignments through the calendar", async () => {
    const assignments = "/api/v1/courses/42/assignments";
    const calendar = "/api/v1/calendar_events";
    const calendarRows = [
        { context_code: "course_42", start_at: "2026-11-29T14:59:00Z", assignment: {id: 9, name: "Recovered"} },
        { context_code: "course_43", start_at: "2026-11-29T14:59:00Z", assignment: {id: 8, name: "Other course"} },
    ];
    const fetch = transport({overrides: {[calendar]: calendarRows}});
    const result = await run("13", false, async (url, settings) => {
        if (url.pathname === "/api/v1/courses/42/assignment_groups" || url.searchParams.get("page") === "2")
            return {status:403, ok:false};
        if (url.pathname === assignments) {
            const first = await fetch(url, settings);
            first.headers.set("Link", `<${origin}${assignments}?page=2>; rel="next"`);
            return first;
        }
        if (url.pathname === calendar) {
            assert.equal(url.searchParams.get("type"), "assignment");
            assert.deepEqual(url.searchParams.getAll("context_codes[]"), ["course_42"]);
        }
        return fetch(url, settings);
    });
    assert.deepEqual(result.courses[0].assignments.map(row => row.id), ["canvas:42:assignment:4", "canvas:42:assignment:9"]);
    assert.equal(result.courses[0].assignmentSource, "partial");
    assert.equal(result.deadlineReport.calendarUsed, 1);
});

test("retrieves a missing assignment by its signed-in student's submission ID", async () => {
    const detail = "/api/v1/courses/42/assignments/4";
    const calls = [];
    const result = await run("13", false, (url, settings) => {
        calls.push(url.pathname);
        if (url.pathname.startsWith("/api/v1/") && (url.pathname.endsWith("/assignments") ||
            url.pathname.endsWith("/assignment_groups") || url.pathname === "/api/v1/planner/items")) return {status:403,ok:false};
        if (url.pathname === detail) return { ok:true, headers:new Headers(),
            text: async () => JSON.stringify({id:4,name:"Recovered from submission ID",due_at:"2026-11-30T14:59:00Z"}) };
        return transport()(url, settings);
    });
    assert.equal(result.courses[0].assignments[0].id, "canvas:42:assignment:4");
    assert.equal(result.courses[0].assignments[0].due, "2026-11-30T14:59:00.000Z");
    assert.equal(result.deadlineReport.planner, "auth");
    assert.ok(calls.includes(detail));
});
