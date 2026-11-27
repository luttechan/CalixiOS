if (location.origin !== "https://canvas.bufs.ac.kr") throw Error("AUTH_REQUIRED");

const parse = (body) => JSON.parse(body.trimStart().replace(/^while\s*\(\s*1\s*\)\s*;/, ""));
const request = async (path, learning = false, validator = null) => {
    const url = new URL(path, location.origin);
    if (url.origin !== location.origin) throw Error("UNEXPECTED_ORIGIN");
    const headers = { Accept: "application/json" };
    if (typeof validator === "string" && /^"[^"\r\n]{1,250}"$/.test(validator)) headers["If-None-Match"] = validator;
    if (learning) {
        const token = document.cookie.match(/(?:^|;\s*)xn_api_token=([^;]*)/)?.[1];
        if (token) headers.Authorization = "Bearer " + decodeURIComponent(token);
    }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 12000);
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

const list = async (initial) => {
    const rows = [];
    let next = initial;
    for (let page = 0; next && page < 25; page++) {
        const value = await request(next);
        if (!Array.isArray(value.data)) throw Error("INVALID_LIST");
        rows.push(...value.data);
        next = value.next;
    }
    if (next) throw Error("TOO_MANY_PAGES");
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
        const itemID = id(row.module_item_id ?? data?.module_item_id);
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
                url: link(row.html_url) || link(`/courses/${courseID}/modules`) });
        }
        for (const child of Object.values(row).reverse()) if (child && typeof child === "object") pending.push(child);
    }
    return [...events.values()];
};

const readAttendance = async (course, courseID, root) => {
    const [weeks, statuses, items, summaries] = await Promise.all([
        request(root + "/lessons", true), request(root + "/lessons/attendances", true),
        request(root + "/attendance_items?include_detail=true", true), request(root + "/attendance_items/summary?only_use_attendance=true", true)
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

const readAssignments = async (base) => {
    const query = "exclude_response_fields[]=description&override_assignment_dates=true&per_page=100";
    try {
        const result = await list(base + "/assignments?include[]=submission&" + query);
        if (result.length) return result;
        try {
            const groups = await list(base + "/assignment_groups?include[]=assignments&" + query);
            return groups.flatMap((group) => Array.isArray(group.assignments) ? group.assignments : []);
        } catch { return result; }
    } catch {
        const groups = await list(base + "/assignment_groups?include[]=assignments&" + query);
        return groups.flatMap((group) => Array.isArray(group.assignments) ? group.assignments : []);
    }
};

const gather = async (row) => {
    const courseID = id(row?.id);
    if (!courseID) throw Error("INVALID_COURSE");
    const name = clip(row.name || row.course_code) || `과목 ${courseID}`;
    const base = `/api/v1/courses/${courseID}`;
    const learning = `/learningx/api/v1/courses/${courseID}`;
    const cached = typeof knownModules === "object" && knownModules !== null ? knownModules[courseID] : null;
    const [assigned, videos, attendance, submissions] = await Promise.allSettled([
        readAssignments(base),
        (async () => {
            const fallback = typeof window !== "undefined" ? window[Symbol.for("calix.canvas.modules")] : null;
            let response, rows, error;
            try {
                response = await request(learning + "/modules?include_detail=true", true, cached);
                if (response.unchanged) return { rows: null, unchanged: true, validator: response.validator };
                rows = readVideos(name, courseID, response.data);
                if (rows.length || !fallback) return { rows, validator: response.validator };
            } catch (reason) {
                error = reason;
            }
            if (fallback) {
                const native = await fallback.collect(Number(courseID));
                const items = native.items.flatMap((item) => {
                    const itemID = id(item.id);
                    if (!itemID || !item.title) return [];
                    return [{
                        id: `canvas:${courseID}:video:${itemID}`, title: clip(item.title), course: name, kind: "영상",
                        due: date(item.content_details?.due_at), done: item.completed === true,
                        status: item.completed === null ? "unverified" : null, url: link(item.url),
                    }];
                });
                if (items.length || native.complete) return { rows: items, partial: !native.complete };
            }
            if (error) throw error;
            return { rows: rows ?? [], validator: response?.validator };
        })(),
        includeAttendance ? readAttendance(name, courseID, learning) : Promise.resolve(null),
        list(base + `/students/submissions?student_ids[]=${owner}&include[]=submission_comments&include[]=rubric_assessment&per_page=100`)
    ]);
    const enriched = submissions.status === "fulfilled" ? new Map(submissions.value.filter((row) => id(row.user_id) === owner)
        .map((row) => [id(row.assignment_id), row])) : new Map();
    const assignments = assigned.status === "fulfilled" ? assigned.value.flatMap((item) => {
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
        const due = firstDate(item.due_at, submission?.cached_due_date, item.submission?.cached_due_date);
        return [{ id: `canvas:${courseID}:assignment:${assignmentID}`, title: clip(item.name), course: name, kind: "과제",
            due, dueKnown: due !== null || item.due_at === null,
            done: Boolean(submission?.submitted_at) || workflow === "submitted" || workflow === "graded",
            url: link(item.html_url) || link(`${base.replace("/api/v1", "")}/assignments/${assignmentID}`),
            status: submission?.missing ? "missing" : workflow === "graded" ? "graded" : submission?.late ? "late" :
                (workflow === "submitted" || submission?.submitted_at) ? "submitted" : null,
            feedback: labels.join("\n").slice(0, 6000) || null }];
    }) : null;
    const modules = videos.status === "fulfilled" ? videos.value : null;
    return { id: courseID, name, assignments, videos: modules?.rows ?? null, modulesUnchanged: modules?.unchanged ?? false,
        modulesPartial: modules?.partial ?? false,
        modulesVerified: !!modules, modulesValidator: modules?.validator ?? null,
        attendance: attendance.status === "fulfilled" ? attendance.value : null };
};

const output = [];
for (let i = 0; i < courses.length; i += 3) output.push(...await Promise.all(courses.slice(i, i + 3).map(gather)));
return JSON.stringify({ owner, courses: output });
