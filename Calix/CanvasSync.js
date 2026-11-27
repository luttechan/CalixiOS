if (location.origin !== "https://canvas.bufs.ac.kr") throw Error("AUTH_REQUIRED");

const parse = (body) => JSON.parse(body.trimStart().replace(/^while\s*\(\s*1\s*\)\s*;/, ""));
const request = async (path, learning = false, validator = null, timeout = 12000) => {
    const url = new URL(path, location.origin);
    if (url.origin !== location.origin) throw Error("UNEXPECTED_ORIGIN");
    const headers = { Accept: "application/json" };
    if (typeof validator === "string" && /^"[^"\r\n]{1,250}"$/.test(validator)) headers["If-None-Match"] = validator;
    if (learning) {
        const token = document.cookie.match(/(?:^|;\s*)xn_api_token=([^;]*)/)?.[1];
        if (token) headers.Authorization = "Bearer " + decodeURIComponent(token);
    }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeout);
    try {
        const res = await fetch(url, { credentials: "same-origin", redirect: "error", headers, signal: controller.signal });
        if (res.status === 401 || res.status === 403) throw Error("AUTH_REQUIRED");
        if (res.status === 304 && headers["If-None-Match"]) return { unchanged: true, validator };
        if (!res.ok) throw Error(`HTTP_${res.status}`);
        const body = await res.text();
        if (body.length > 8000000) throw Error("RESPONSE_TOO_LARGE");
        const etag = res.headers.get("ETag");
        return { data: parse(body), next: res.headers.get("Link")?.match(/<([^>]+)>;\s*rel="next"/)?.[1],
            validator: etag && /^"[^"\r\n]{1,250}"$/.test(etag) ? etag : null };
    } finally { clearTimeout(timer); }
};

const failureCode = reason => {
    if (reason?.message === "AUTH_REQUIRED") return "auth";
    if (reason?.name === "AbortError") return "timeout";
    return reason?.name === "TypeError" ? "network" : "response";
};

const list = async (initial, partial) => {
    const rows = [];
    let next = initial;
    try {
        for (let page = 0; next && page < 25; page++) {
            const value = await request(next);
            if (!Array.isArray(value.data)) throw Error("INVALID_LIST");
            rows.push(...value.data);
            next = value.next;
        }
        if (next) throw Error("TOO_MANY_PAGES");
    } catch (reason) {
        if (!partial || !rows.length) throw reason;
        partial(failureCode(reason));
    }
    return rows;
};

const id = (value) => {
    const text = String(value ?? "");
    return /^[1-9]\d{0,18}$/.test(text) && (typeof value !== "number" || Number.isSafeInteger(value)) ? text : null;
};
const clip = (value, size = 500) => typeof value === "string" ? value.slice(0, size) : "";
const date = (value) => {
    if (typeof value !== "string") return null;
    let text = value.trim().replace(/^(\d{4}-\d{2}-\d{2}) (?=\d)/, "$1T");
    if (!/^\d{4}-\d{2}-\d{2}(?:T|$)/.test(text)) return null;
    if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?$/.test(text)) text += "+09:00";
    return Number.isFinite(Date.parse(text)) ? new Date(text).toISOString() : null;
};
const firstDate = (...values) => {
    for (const value of values) {
        const parsed = date(value);
        if (parsed) return parsed;
    }
    return null;
};
const periodDue = (value) => Array.isArray(value)
    ? value.map((period) => date(period?.due_at)).filter(Boolean).sort().at(-1)
    : value?.due_at;
const link = (value) => {
    try {
        if (!value) return null;
        const address = new URL(value, location.origin);
        return address.origin === location.origin ? address.href : null;
    } catch { return null; }
};
const mediaTypes = new Set(["movie", "ssz", "syncthink", "estage", "xenoglobal", "oncast", "screenlecture", "lecturecam", "readystream", "webstudio", "everlec", "movie360", "mp4", "zoom", "audio", "youtube", "remix", "metaverse_conference", "video_conference", "external_youtube", "external_video"]);

const readVideos = (course, courseID, body) => {
    const roots = Array.isArray(body) ? body : body?.modules;
    if (!Array.isArray(roots)) throw Error("INVALID_MODULES");
    const events = new Map();
    const pending = [roots];
    let visited = 0;
    while (pending.length) {
        const row = pending.pop();
        if (!row || typeof row !== "object" || row.published === false) continue;
        if (++visited > 40000) throw Error("MODULE_LIMIT");
        const data = row.content_data;
        const media = data?.item_content_data;
        const type = String(media?.content_type || data?.item_content_type || row.content_type || "").toLowerCase();
        const learningItemID = id(data?.item_id) ?? id(row.content_id);
        const moduleID = id(row.module_item_id) ?? id(data?.module_item_id);
        const itemID = moduleID ?? learningItemID;
        const movingImage = mediaTypes.has(type) || (type === "embed" && mediaTypes.has(String(media?.content_subtype || "").toLowerCase())) ||
            (media?.progress_support === true && Number(media.duration) > 0);
        const title = clip(row.title || data?.title || media?.title);
        if (itemID && data && movingImage && title) {
            const key = `canvas:${courseID}:video:${itemID}`;
            const status = String(row.attendance_status ?? data?.attendance_status ?? "").toLowerCase();
            const due = firstDate(row.due_at, data.due_at, media?.due_at, periodDue(row.lecture_periods),
                periodDue(data.lecture_periods), periodDue(media?.lecture_periods));
            const done = row.completed === true || ["attendance", "present", "excused", "late", "complete", "completed"].includes(status);
            const previous = events.get(key);
            events.set(key, { id: key, title, course, kind: "영상", due: due ?? previous?.due ?? null,
                done: done || previous?.done === true, status: status || previous?.status || null,
                learningItemID: learningItemID ?? previous?.learningItemID,
                url: link(row.html_url) || link(row.url) || link(moduleID
                    ? `/courses/${courseID}/modules/items/${moduleID}` : `/courses/${courseID}/modules`) });
        }
        for (const child of Object.values(row).reverse()) if (child && typeof child === "object") pending.push(child);
    }
    return [...events.values()];
};

const renderedDate = (value, year) => {
    if (/^\d{4}-\d{2}-\d{2}/.test(value)) return date(value);
    const match = /(?:(20\d{2})년\s*)?(\d{1,2})월\s*(\d{1,2})일\s*(오전|오후)?\s*(\d{1,2}):(\d{2})/.exec(value);
    if (!match || !(match[1] || year)) return null;
    const y = Number(match[1] || year), month = Number(match[2]), day = Number(match[3]), minute = Number(match[6]);
    let hour = Number(match[5]);
    if (match[4]) {
        if (hour > 12) return null;
        hour = hour % 12 + (match[4] === "오후" ? 12 : 0);
    }
    const stamp = new Date(Date.UTC(y, month - 1, day, hour, minute));
    if (stamp.getUTCMonth() !== month - 1 || stamp.getUTCDate() !== day || hour > 23 || minute > 59) return null;
    return new Date(stamp.getTime() - 9 * 3600000).toISOString();
};

const readLearningFrame = async (course, courseID, owner, entry) => {
    if (typeof document.createElement !== "function" || !document.documentElement) return null;
    const coursePath = `/courses/${courseID}`;
    const toolPath = new RegExp(`^${coursePath}/external_tools/[1-9]\\d*/?$`);
    const toolURL = value => {
        const address = link(value);
        return address && toolPath.test(new URL(address).pathname) ? address : null;
    };
    const frame = document.createElement("iframe");
    frame.setAttribute("aria-hidden", "true");
    frame.setAttribute("tabindex", "-1");
    frame.setAttribute("sandbox", "allow-scripts allow-same-origin allow-forms");
    frame.style.cssText = "position:fixed;top:0;left:0;width:390px;height:760px;opacity:0;pointer-events:none;z-index:-1";
    let selectedTool = toolURL(entry);
    frame.src = selectedTool ?? location.origin + coursePath;
    document.documentElement.appendChild(frame);
    const stop = Date.now() + 11000;
    let result = null;
    try {
        while (Date.now() < stop) {
            const queue = [frame];
            let visited = 0;
            while (queue.length && ++visited <= 25) {
                const child = queue.shift();
                let doc;
                try { doc = child.contentDocument; } catch { continue; }
                if (!doc || !link(doc.URL) || !doc.URL.startsWith(location.origin + "/")) continue;
                const root = doc.querySelector("#root[data-canvas_course_id]");
                if (root?.getAttribute("data-canvas_course_id") === courseID &&
                        (!root.getAttribute("data-user_id") || root.getAttribute("data-user_id") === owner)) {
                    const year = /\b(20\d{2})(?:년|학년도)/.exec(root.getAttribute("data-term") || "")?.[1];
                    const rows = [];
                    const folded = root.querySelectorAll('.xnmb-module-left-wrapper[aria-expanded="false"]');
                    for (const week of folded) week.click();
                    for (const item of root.querySelectorAll(".xnmb-module_item-wrapper")) {
                        const icon = item.querySelector(".xnmb-module_item-icon");
                        const meta = item.querySelector(".xnmb-module_item-meta_data-wrapper") ?? item;
                        const anchor = meta.querySelector("a.xnmb-module_item-left-title.link");
                        const address = link(anchor?.getAttribute("href"));
                        const moduleID = address && new RegExp(`^${coursePath}/modules/items/([1-9]\\d*)/?$`).exec(new URL(address).pathname)?.[1];
                        const title = clip(anchor?.textContent?.trim());
                        if (!moduleID || !title || !Array.from(icon?.classList ?? []).some(type => mediaTypes.has(type))) continue;
                        const period = meta.querySelector(".xnlal-attendance-list-item-meta_data-lecture_periods-due_at");
                        const completed = item.querySelector(".xnmb-module_item-completed")?.classList;
                        rows.push({
                            id: `canvas:${courseID}:video:${moduleID}`, title, course, kind: "영상", url: address,
                            due: renderedDate(period?.textContent?.trim() ?? "", year), done: completed?.contains("completed") === true,
                            status: completed?.contains("completed") || completed?.contains("incomplete") ? null : "unverified",
                        });
                    }
                    result = rows;
                    if (!folded.length && (rows.some(row => row.due) ||
                        (rows.length > 0 && /(?:^|;\s*)xn_api_token=/.test(document.cookie)))) return result;
                }
                if (!selectedTool && new URL(doc.URL).pathname.startsWith(coursePath)) {
                    for (const anchor of doc.querySelectorAll("a[href]")) {
                        if (!/주차학습|학습콘텐츠|강의콘텐츠|온라인강의|LearningX/i.test(anchor.textContent)) continue;
                        selectedTool = toolURL(anchor.getAttribute("href"));
                        if (selectedTool) { frame.src = selectedTool; break; }
                    }
                }
                queue.push(...doc.querySelectorAll("iframe"));
            }
            await new Promise(resolve => setTimeout(resolve, 200));
        }
        return result;
    } finally {
        frame.remove();
    }
};

const supplementVideoDates = async (rows, loadItems) => {
    if (!rows.some(row => !row.due && row.learningItemID)) return;
    const items = (await loadItems().catch(() => null))?.data?.attendance_items;
    if (!Array.isArray(items)) return;
    const dueByID = new Map();
    for (const item of items) {
        const key = id(item?.item_id);
        const due = firstDate(item?.due_at, item?.item_content_data?.due_at);
        if (key && due && item.published !== false) {
            dueByID.set(key, dueByID.has(key) && dueByID.get(key) !== due ? null : due);
        }
    }
    for (const row of rows) row.due ??= dueByID.get(row.learningItemID) ?? null;
};

const readAttendance = async (course, courseID, root, attendanceItems) => {
    const [weeks, statuses, items, summaries] = await Promise.all([
        request(root + "/lessons", true), request(root + "/lessons/attendances", true),
        attendanceItems(), request(root + "/attendance_items/summary?only_use_attendance=true", true)
    ]);
    if (!Array.isArray(weeks.data) || !Array.isArray(statuses.data) || !Array.isArray(items.data?.attendance_items) ||
        !summaries.data?.attendance_summaries) throw Error("INVALID_ATTENDANCE");
    const index = new Map(statuses.data.map((row) => [`${row.week_position}:${row.lesson_position}`, clip(row.attendance_status, 80)]));
    const rows = new Map();
    for (const week of weeks.data) {
        for (const lesson of (Array.isArray(week.lessons) ? week.lessons : [])) {
            const w = week.week_position, l = lesson.lesson_position;
            if (!Number.isSafeInteger(w) || !Number.isSafeInteger(l)) continue;
            const key = `lesson:${courseID}:${w}:${l}`;
            rows.set(key, { id: key, course, title: `${w}주차 ${l}차시`, status: index.get(`${w}:${l}`) || "none",
                date: date(lesson.makeup_date || lesson.class_date || lesson.display_class_date) });
        }
    }
    for (const item of items.data.attendance_items) {
        const itemID = id(item.item_id);
        if (!itemID || item.published === false || item.use_attendance === false) continue;
        const key = `item:${courseID}:${itemID}`;
        const summary = summaries.data.attendance_summaries[itemID];
        rows.set(key, { id: key, course, title: clip(item.title) || "학습 출결", status: clip(summary?.attendance_status, 80) || "none", date: date(item.due_at) });
    }
    return [...rows.values()];
};

const profile = (await request("/api/v1/users/self/profile")).data;
const owner = id(profile?.id);
if (!owner) throw Error("AUTH_REQUIRED");
if (expectedOwner && owner !== expectedOwner) throw Error("ACCOUNT_CHANGED");
const courses = await list("/api/v1/courses?enrollment_type=student&enrollment_state=active&per_page=100");
if (courses.length > 180) throw Error("COURSE_LIMIT");

const today = Date.now();
const day = 86400000;
const start = new Date(today - 180 * day).toISOString().slice(0, 10);
const end = new Date(today + 90 * day).toISOString().slice(0, 10);
const windowQuery = `start_date=${start}&end_date=${end}&per_page=100`;

const readPlanner = async () => {
    const active = new Set(courses.map(course => id(course?.id)));
    const indexed = new Map();
    let problem = null;
    for (const row of await list("/api/v1/planner/items?" + windowQuery, error => { problem = error; })) {
        const courseID = id(row?.course_id), assignmentID = id(row?.plannable_id);
        if (!courseID || !active.has(courseID) || !assignmentID || row.plannable_type !== "assignment" ||
            (row.plannable?.id != null && id(row.plannable.id) !== assignmentID)) continue;
        const due = firstDate(row.plannable?.due_at, row.plannable?.due_at === null ? null : row.plannable_date);
        const key = `canvas:${courseID}:assignment:${assignmentID}`;
        const source = row.submissions;
        indexed.set(key, {
            id: key, title: clip(row.plannable?.title), kind: "과제", course: clip(row.context_name),
            due, dueKnown: due !== null || row.plannable?.due_at === null, done: source?.submitted === true || source?.graded === true,
            status: source?.graded === true ? "graded" : source?.submitted === true ? "submitted" : null,
            url: link(row.html_url) || link(`/courses/${courseID}/assignments/${assignmentID}`),
        });
    }
    return {rows: indexed, status: problem ? "partial" : indexed.size ? "ok" : "empty"};
};
const plannerPromise = readPlanner().catch(reason => ({rows: new Map(), status: failureCode(reason)}));

const recoverCalendar = async courseIDs => {
    const context = courseIDs.map(key => `context_codes[]=course_${key}`).join("&");
    let partial = false;
    const rows = await list("/api/v1/calendar_events?type=assignment&" + windowQuery + "&" + context, () => { partial = true; });
    const events = new Map();
    for (const row of rows) {
        const assignment = row?.assignment;
        const courseID = /^course_([1-9]\d{0,18})$/.exec(row?.context_code ?? assignment?.context_code ?? "")?.[1];
        const assignmentID = id(assignment?.id);
        const title = clip(assignment?.name || row?.title);
        if (!courseIDs.includes(courseID) || !assignmentID || !title || assignment.published === false ||
            (assignment.course_id != null && id(assignment.course_id) !== courseID)) continue;
        const key = `canvas:${courseID}:assignment:${assignmentID}`;
        const due = firstDate(row.start_at, assignment.due_at);
        const submission = assignment.submission;
        events.set(key, { id:key, title, kind:"과제", due, dueKnown:due !== null,
            done:Boolean(submission?.submitted_at) || ["submitted", "graded"].includes(submission?.workflow_state),
            url:link(assignment.html_url || row.html_url) || link(`/courses/${courseID}/assignments/${assignmentID}`) });
    }
    return {rows: events, status: partial ? "partial" : events.size ? "ok" : "empty"};
};

const readAssignments = async (base) => {
    const query = "exclude_response_fields[]=description&override_assignment_dates=true&per_page=100";
    const records = new Map();
    const put = rows => {
        for (const row of rows) {
            const key = id(row?.id);
            if (key && !records.has(key)) records.set(key, row);
        }
    };
    let problem = null;
    let answered = false;
    try {
        put(await list(base + "/assignments?include[]=submission&" + query, error => { problem = error; }));
        answered = true;
        if (records.size && !problem) return {rows: [...records.values()], status: "ok"};
    } catch (reason) { problem = failureCode(reason); }
    try {
        let groupsPartial = false;
        const groups = await list(base + "/assignment_groups?include[]=assignments&" + query, () => { groupsPartial = true; });
        answered = true;
        put(groups.flatMap(group => Array.isArray(group.assignments) ? group.assignments : []));
        if (records.size) return {rows: [...records.values()], status: groupsPartial ? "partial" : problem ? "fallback" : "ok"};
    } catch (reason) {
        problem ??= failureCode(reason);
    }
    return {rows: records.size ? [...records.values()] : answered ? [] : null, status: records.size ? "partial" : problem ?? "empty"};
};

const gather = async (row) => {
    const courseID = id(row?.id);
    if (!courseID) throw Error("INVALID_COURSE");
    const name = clip(row.name || row.course_code) || `과목 ${courseID}`;
    const base = `/api/v1/courses/${courseID}`;
    const learning = `/learningx/api/v1/courses/${courseID}`;
    const cached = typeof knownModules === "object" && knownModules !== null ? knownModules[courseID] : null;
    let attendanceRequest;
    const attendanceItems = () => attendanceRequest ??= request(learning + "/attendance_items?include_detail=true", true);
    const submissionPath = base + `/students/submissions?student_ids[]=${owner}&include[]=submission_comments&include[]=rubric_assessment&per_page=100`;
    const [assigned, videos, attendance, submissions] = await Promise.allSettled([
        readAssignments(base),
        (async () => {
            const fallback = typeof window !== "undefined" ? window[Symbol.for("calix.canvas.modules")] : null;
            let response, rows, error;
            try {
                response = await request(learning + "/modules?include_detail=true", true, cached);
                if (response.unchanged) return { rows: null, unchanged: true, validator: response.validator };
                rows = readVideos(name, courseID, response.data);
                const needsDates = rows.some(row => !row.due);
                if (needsDates) await supplementVideoDates(rows, attendanceItems);
                if ((rows.length && rows.every(row => row.due)) || !fallback)
                    return { rows, validator: needsDates ? null : response.validator };
            } catch (reason) {
                error = reason;
            }
            if (fallback) {
                const native = await fallback.collect(Number(courseID)).catch(() => null);
                const items = (native?.items ?? []).flatMap((item) => {
                    const itemID = id(item.id);
                    if (!itemID || !item.title) return [];
                    return [{
                        id: `canvas:${courseID}:video:${itemID}`, title: clip(item.title), course: name, kind: "영상",
                        due: date(item.content_details?.due_at), done: item.completed === true,
                        status: item.completed === null ? "unverified" : null, url: link(item.url),
                    }];
                });
                const rendered = native?.learningx?.present === false ? null :
                    await readLearningFrame(name, courseID, owner, native?.learningx?.url).catch(() => null);
                if (rendered !== null) {
                    const refreshed = await request(learning + "/modules?include_detail=true", true, null, 4500)
                        .then(result => readVideos(name, courseID, result.data)).catch(() => []);
                    await supplementVideoDates(refreshed, () => request(learning + "/attendance_items?include_detail=true", true, null, 4500));
                    const merged = new Map();
                    for (const row of [...items, ...rendered, ...(rows ?? []), ...refreshed]) {
                        const old = merged.get(row.id);
                        merged.set(row.id, {...row, due: row.due ?? old?.due ?? null, url: row.url ?? old?.url});
                    }
                    return { rows: [...merged.values()], partial: merged.size === 0 || refreshed.length === 0 };
                }
                if (items.length || rows?.length || native?.complete) {
                    const merged = new Map(items.map(row => [row.id, row]));
                    for (const row of rows ?? []) {
                        const old = merged.get(row.id);
                        merged.set(row.id, {...row, due: row.due ?? old?.due ?? null});
                    }
                    return { rows: [...merged.values()], partial: !native?.complete };
                }
            }
            if (error) throw error;
            return { rows: rows ?? [], validator: response?.validator };
        })(),
        includeAttendance ? readAttendance(name, courseID, learning, attendanceItems) : Promise.resolve(null),
        list(submissionPath)
    ]);
    const ownSubmissions = rows => rows.filter(row => id(row?.user_id) === owner);
    const enriched = submissions.status === "fulfilled" ? new Map(ownSubmissions(submissions.value)
        .map((row) => [id(row.assignment_id), row])) : new Map();
    const assignmentSource = assigned.status === "fulfilled" ? assigned.value.status : failureCode(assigned.reason);
    let assignedItems = assigned.status === "fulfilled" ? assigned.value.rows : null;
    if (!assignedItems?.length && enriched.size) {
        const withAssignments = await list(submissionPath + "&include[]=assignment").catch(() => []);
        const fromSubmissions = [];
        for (const submission of ownSubmissions(withAssignments)) {
            const assignmentID = id(submission.assignment_id);
            if (!assignmentID || id(submission.assignment?.id) !== assignmentID) continue;
            if (!enriched.has(assignmentID)) enriched.set(assignmentID, submission);
            fromSubmissions.push(submission.assignment);
        }
        if (fromSubmissions.length) assignedItems = fromSubmissions;
    }
    if (assignmentSource !== "ok" && enriched.size) {
        const known = new Set((assignedItems ?? []).map(item => id(item.id)));
        const missing = [...enriched.keys()].filter(key => key && !known.has(key)).slice(0, 24);
        for (let i = 0; i < missing.length; i += 4) {
            const results = await Promise.all(missing.slice(i, i + 4).map(async key => {
                const response = await request(base + `/assignments/${key}?include[]=submission&override_assignment_dates=true`, false, null, 4000).catch(() => null);
                return id(response?.data?.id) === key ? response.data : null;
            }));
            const recovered = results.filter(Boolean);
            if (recovered.length) assignedItems = [...(assignedItems ?? []), ...recovered];
        }
    }
    const assignments = assignedItems?.flatMap((item) => {
        const assignmentID = id(item?.id);
        if (!assignmentID || !item.name || item.published === false) return [];
        const submission = enriched.get(assignmentID) || item.submission;
        const workflow = clip(submission?.workflow_state, 40);
        const labels = [];
        if (submission?.missing) labels.push("미제출");
        if (submission?.late) labels.push("지각 제출");
        if (workflow === "graded") labels.push("채점 완료");
        else if (workflow === "submitted" || submission?.submitted_at) labels.push("제출 완료");
        for (const comment of (Array.isArray(submission?.submission_comments) ? submission.submission_comments : [])) {
            if (comment?.comment) labels.push(clip(comment.comment, 2000));
        }
        for (const criterion of Object.values(submission?.rubric_assessment || {})) {
            if (criterion?.comments) labels.push(clip(criterion.comments, 2000));
        }
        const due = firstDate(submission?.cached_due_date, item.submission?.cached_due_date, item.due_at);
        return [{ id: `canvas:${courseID}:assignment:${assignmentID}`, title: clip(item.name), course: name, kind: "과제",
            due, dueKnown: due !== null || (item.due_at === null && submission?.cached_due_date === null),
            done: Boolean(submission?.submitted_at) || workflow === "submitted" || workflow === "graded",
            url: link(item.html_url) || link(`${base.replace("/api/v1", "")}/assignments/${assignmentID}`),
            status: submission?.missing ? "missing" : workflow === "graded" ? "graded" : submission?.late ? "late" :
                (workflow === "submitted" || submission?.submitted_at) ? "submitted" : null,
            feedback: labels.join("\n").slice(0, 6000) || null }];
    }) ?? null;
    const modules = videos.status === "fulfilled" ? videos.value : null;
    return { id: courseID, name, assignments, videos: modules?.rows ?? null, modulesUnchanged: modules?.unchanged ?? false,
        modulesPartial: modules?.partial ?? false,
        modulesVerified: !!modules, modulesValidator: modules?.validator ?? null,
        assignmentSource, videoSource: modules ? modules.unchanged ? "cache" : modules.partial ? "partial" : "ok" : failureCode(videos.reason),
        attendance: attendance.status === "fulfilled" ? attendance.value : null };
};

const output = [];
for (let i = 0; i < courses.length; i += 3) output.push(...await Promise.all(courses.slice(i, i + 3).map(gather)));
const planner = await plannerPromise;
const affected = output.filter(course => course.assignmentSource !== "ok" || !course.assignments?.length).map(course => course.id);
let calendarStatus = "skipped", calendarUsed = 0, plannerUsed = 0;
const calendar = new Map();
for (let i = 0; i < affected.length; i += 10) {
    const recovered = await recoverCalendar(affected.slice(i, i + 10)).catch(reason => ({rows: new Map(), status: failureCode(reason)}));
    calendarStatus = calendarStatus === "skipped" || calendarStatus === recovered.status ? recovered.status : "partial";
    for (const [key, row] of recovered.rows) calendar.set(key, row);
}
for (const course of output) {
    const prefix = `canvas:${course.id}:assignment:`;
    const assignments = new Map((course.assignments ?? []).map(event => [event.id, event]));
    for (const row of calendar.values()) {
        if (!row.id.startsWith(prefix)) continue;
        const saved = assignments.get(row.id);
        if (saved && !saved.due && row.due) {
            saved.due = row.due;
            saved.dueKnown = true;
            calendarUsed++;
        } else if (!saved) {
            assignments.set(row.id, {...row, course: course.name});
            calendarUsed++;
        }
    }
    for (const row of planner.rows.values()) {
        if (!row.id.startsWith(prefix)) continue;
        const saved = assignments.get(row.id);
        if (saved && row.due) {
            saved.due = row.due;
            saved.dueKnown = true;
            plannerUsed++;
        } else if (!saved && row.title) {
            assignments.set(row.id, {...row, course: course.name});
            plannerUsed++;
        }
    }
    if (assignments.size) course.assignments = [...assignments.values()];
}
return JSON.stringify({ owner, courses: output, deadlineReport: {
    planner: planner.status, plannerUsed, calendar: calendarStatus, calendarUsed,
} });
