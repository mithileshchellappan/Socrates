# Phone

The iPhone's shell (M7, docs/plan-m7.md §5.2; mockups 09 and 16, DESIGN 6.7, 8.5): `PhoneShell`
(the floating tab bar Today, Courses, Calendar, Mail; the separate round red Record button; the
agent bubble in each tab's header and the agent sheet while it is available) and `PhoneTab`. The app
passes the screens in (Today is CoursesUI's `TodayView` at compact width) and presents Recorder's
`RecorderScreen` on Record.

Status: skeleton landed with the plan (contracts only). Workstream B replaces this README with
entry points, "Requests for the integrator" and "Design notes for the integrator".
