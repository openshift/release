#!/usr/bin/env -S bash -c 'python3 -m venv "$(dirname "$0")"/.venv && source "$(dirname "$0")"/.venv/bin/activate && pip3 --require-virtualenv --no-input --disable-pip-version-check install PyYAML==6.0 dataclasses >/dev/null && exec python3 "$0" $*'
# The magic above inits virtual environment in the directory of the script to install PyYAML there and starts Python
# to actually execute this script. It all can be done manually but requires writing readme and users following it
# whereas having a self-sufficient script should be more user-friendly.

"""
The script reads ci-operator yaml config files from the current directory as well as corresponding job configs and
outputs an overview table for visual controlling the configuration between multiple files.

The script requires Python 3.7 or newer to run.
"""

import argparse
import html
import io
import os.path
import pathlib
import sys
import subprocess
import typing

import dataclasses
import yaml


@dataclasses.dataclass
class BaseImageEntry:
    name: str
    raw_entry: typing.Any

    @property
    def tag(self):
        return safe_get_attr(self.raw_entry, "tag", coalesce_to="?")


@dataclasses.dataclass
class BaseImageEntries:
    """`base_images` attribute of config YAML file (the one under `ci-operator/config/**` directory)."""
    unordered_entries: typing.List[BaseImageEntry] = None
    ordered_entries: typing.List[BaseImageEntry] = None


@dataclasses.dataclass
class TestEntry:
    raw_entry: typing.Any

    @property
    def name(self):
        return safe_get_attr(self.raw_entry, "as")

    @property
    def is_cron(self):
        return safe_get_attr(self.raw_entry, "cron") is not None

    @property
    def is_postsubmit(self):
        return safe_get_attr(self.raw_entry, "postsubmit") == True

    @property
    def is_optional(self):
        return safe_get_attr(self.raw_entry, "optional") == True

    @property
    def has_always_run(self):
        return safe_get_attr(self.raw_entry, "always_run") is not None

    @property
    def always_run(self):
        return safe_get_attr(self.raw_entry, "always_run")

    @property
    def has_run_if_changed(self):
        return safe_get_attr(self.raw_entry, "run_if_changed") is not None

    @property
    def run_if_changed(self):
        return safe_get_attr(self.raw_entry, "run_if_changed")

    @property
    def has_skip_if_only_changed(self):
        return safe_get_attr(self.raw_entry, "skip_if_only_changed") is not None

    @property
    def skip_if_only_changed(self):
        return safe_get_attr(self.raw_entry, "skip_if_only_changed")


@dataclasses.dataclass
class ConfigFile:
    """Represents YAML file under `ci-operator/config/**` directory."""

    filename: str
    load_error: Exception
    raw_parsed_yaml: typing.Any
    short_filename: str = None

    unordered_entries: typing.List[TestEntry] = None
    ordered_entries: typing.List[TestEntry] = None

    base_images: BaseImageEntries = None

    @property
    def branch(self):
        return safe_get_attr(self.raw_parsed_yaml, "zz_generated_metadata.branch", coalesce_to="")

    @property
    def variant(self):
        return safe_get_attr(self.raw_parsed_yaml, "zz_generated_metadata.variant", coalesce_to="")

    @property
    def build_root_tag(self):
        return safe_get_attr(self.raw_parsed_yaml, "build_root.image_stream_tag.tag")

    def dump_build_root(self):
        return dump_dict_subset(self.raw_parsed_yaml, ["build_root"])

    @property
    def ocp_release(self):
        if not safe_get_attr(self.raw_parsed_yaml, "releases"):
            return ""
        version = safe_get_attr(self.raw_parsed_yaml, "releases.latest.release.version")
        if not version:
            return "?"
        channel = safe_get_attr(self.raw_parsed_yaml, "releases.latest.release.channel", coalesce_to="?")
        return f"{version}@{channel}"

    def dump_ocp_release(self):
        return dump_dict_subset(self.raw_parsed_yaml, ["releases"])


@dataclasses.dataclass
class JobEntry:
    raw_entry: typing.Any

    @staticmethod
    def __strip_prefix(prefix, str):
        start = len(prefix) if str.startswith(prefix) else 0
        return str[start:]

    @property
    def name(self):
        context_attr = safe_get_attr(self.raw_entry, "context")
        if context_attr is None:
            return None
        return self.__strip_prefix("ci/prow/", context_attr)

    @property
    def always_run(self):
        return safe_get_attr(self.raw_entry, "always_run")

    @property
    def has_run_if_changed(self):
        return safe_get_attr(self.raw_entry, "run_if_changed") is not None

    @property
    def run_if_changed(self):
        return safe_get_attr(self.raw_entry, "run_if_changed")

    @property
    def has_skip_if_only_changed(self):
        return safe_get_attr(self.raw_entry, "skip_if_only_changed") is not None

    @property
    def skip_if_only_changed(self):
        return safe_get_attr(self.raw_entry, "skip_if_only_changed")

    def dump_all_interesting_attrs(self):
        """
        Returns YAML dump of attributes that can be self-managed (for presubmits jobs).
        See https://docs.ci.openshift.org/docs/how-tos/contributing-openshift-release/#tolerated-changes-to-generated-jobs
        """
        if self.raw_entry is None:
            return ""

        return dump_dict_subset(
            self.raw_entry,
            ["always_run", "run_if_changed", "skip_if_only_changed", "skip_report", "max_concurrency"])


@dataclasses.dataclass
class JobsFile:
    """Represents YAML file under `ci-operator/jobs/**` directory."""
    filename: str
    load_error: Exception
    raw_parsed_yaml: typing.Any
    short_filename: str = None

    unordered_entries: typing.List[JobEntry] = None
    ordered_entries: typing.List[JobEntry] = None


@dataclasses.dataclass
class Data:
    """The entire bag of data this program operates with."""

    config_dir: pathlib.Path

    all_test_names: typing.List[str] = None
    configs: typing.List[ConfigFile] = None

    all_base_image_names: typing.List[str] = None

    all_job_names: typing.List[str] = None
    jobs_files: typing.List[JobsFile] = None

    git_describe_output: str = None

    @property
    def target_repo(self):
        """Returns org/name for the repo of `config_dir`."""
        return "/".join(self.config_dir.resolve().parts[-2:])

    @property
    def jobs_dir(self):
        """Derives `jobs` dir from `config` dir."""
        dir = self.config_dir.resolve()  # repo_root/ci-operator/config/stackrox/stackrox
        dir = dir.parent.parent.parent  # Dir is now at repo_root/ci-operator
        return dir / "jobs" / self.target_repo

    @property
    def config_dir_relative(self):
        """Returns `ci-operator/config/<org>/<repo>`."""
        return self.__relative_dir(self.config_dir)

    @property
    def jobs_dir_relative(self):
        """Returns `ci-operator/jobs/<org>/<repo>`."""
        return self.__relative_dir(self.jobs_dir)

    @staticmethod
    def __relative_dir(dir):
        abs_dir_parts = dir.resolve().parts
        idx = abs_dir_parts.index("ci-operator")
        return "/".join(abs_dir_parts[idx:])

    @property
    def base_images(self):
        return [c.base_images for c in self.configs]


def safe_get_attr(raw_data, attr_key, coalesce_to=None):
    """
    Traverses `raw_data` data structure of nested maps and returns an attribute pointed by `attr_key`.
    I.e. this is some kind of poor-man's XPath.
    `attr_key` can be dot-separated, in which case each part serves as a key for the corresponding level of nested maps.
    Returns None if `raw_data` is None or `attr_key` does not resolve to anything.
    """
    location = raw_data
    for key_part in attr_key.split("."):
        if location is None:
            return None
        if key_part not in location:
            return None
        location = location[key_part]
    return coalesce(location, default=coalesce_to)


def dump_dict_subset(src_dict, keys):
    src_dict = coalesce(src_dict, {})
    subset = {key: src_dict[key] for key in keys if key in src_dict}
    return yaml.safe_dump(subset)


def coalesce(val, default):
    return val if val is not None else default


#########################################################
#### Load and massage data


def load_and_massage_data(dir):
    d = Data(config_dir=dir.resolve())

    d.configs = load_raw_yamls(d.config_dir, constructor_fn=ConfigFile)
    assign_short_filenames(d.configs)
    d.configs = sort_by_short_names(d.configs)
    populate_unordered_tests(d.configs)
    d.all_test_names = extract_and_sort_unique_names(d.configs, use_stackrox_sort_key=True)
    populate_ordered_entries(d.all_test_names, d.configs)

    populate_base_image_entries(d.configs)
    d.all_base_image_names = extract_and_sort_unique_names(d.base_images, use_stackrox_sort_key=False)
    populate_ordered_entries(d.all_base_image_names, d.base_images)

    d.jobs_files = load_raw_yamls(d.jobs_dir, constructor_fn=JobsFile)
    # Postsubmits and periodics have much less degree of customization, so we filter them out.
    d.jobs_files = filter_out_all_but_presubmits_jobs_files(d.jobs_files)
    assign_short_filenames(d.jobs_files)
    d.jobs_files = sort_by_short_names(d.jobs_files)
    populate_unordered_jobs(d.jobs_files)
    d.all_job_names = extract_and_sort_unique_names(d.jobs_files, use_stackrox_sort_key=True)
    populate_ordered_entries(d.all_job_names, d.jobs_files)

    d.git_describe_output = describe_git(d.config_dir)

    return d


def load_raw_yamls(dir, constructor_fn):
    items = []
    for f in dir.glob("*.yaml"):
        filename = f.name
        load_error = None
        raw_parsed_yaml = None
        try:
            raw_parsed_yaml = yaml.safe_load(f.read_text(encoding='utf-8'))
        except Exception as ex:
            load_error = ex
        x = constructor_fn(filename=filename, load_error=load_error, raw_parsed_yaml=raw_parsed_yaml)
        items.append(x)
    return items


def filter_out_all_but_presubmits_jobs_files(jobs_files):
    return [j for j in jobs_files if j.filename.endswith("-presubmits.yaml")]


def assign_short_filenames(items):
    fns = [x.filename for x in items]
    prefix = os.path.commonprefix(fns)
    for x in items:
        x.short_filename = x.filename[len(prefix):] if len(prefix) < len(x.filename) else x.filename
        x.short_filename = pathlib.Path(x.short_filename).stem


def sort_by_short_names(items):
    return sorted(items, key=lambda c: c.short_filename)


def populate_unordered_tests(configs):
    for c in configs:
        c.unordered_entries = []
        for raw_test in safe_get_attr(c.raw_parsed_yaml, "tests", coalesce_to=[]):
            te = TestEntry(raw_entry=raw_test)
            if te.name:
                c.unordered_entries.append(te)


def populate_unordered_jobs(jobs_files):
    for j in jobs_files:
        j.unordered_entries = []
        presubmits_dict = safe_get_attr(j.raw_parsed_yaml, "presubmits", coalesce_to={})
        if len(presubmits_dict) == 0:
            continue
        if len(presubmits_dict) > 1:
            j.load_error = "Unexpected to see too many items under presubmits"
            continue
        # There's only one attribute under `presubmits` in YAML and its name is key is repo name.
        # The following line gets value of that attribute.
        jobs_list = list(presubmits_dict.values())[0]
        for raw_job in jobs_list:
            je = JobEntry(raw_entry=raw_job)
            if je.name:
                j.unordered_entries.append(je)


def populate_base_image_entries(configs):
    for c in configs:
        base_images_raw = safe_get_attr(c.raw_parsed_yaml, "base_images", coalesce_to={})
        unordered_entries = []
        for name, image_raw in base_images_raw.items():
            unordered_entries.append(BaseImageEntry(name=name, raw_entry=image_raw))
        c.base_images = BaseImageEntries(unordered_entries=unordered_entries)


def extract_and_sort_unique_names(items, use_stackrox_sort_key=False):
    """
    Collects and orders unique names of each entry in unordered_entries of each item.
    Works both with ConfigFile/TestEntry and JobsFile/JobEntry.
    """

    def stackrox_sort_key(name):
        """
        Makes `merge-blah` names immediately follow `blah` names.
        Also groups things like `anything-qa-e2e-tests` together.
        """
        return "-".join(reversed(name.split("-")))

    all_names_set = set()
    for x in items:
        for y in x.unordered_entries:
            all_names_set.add(y.name)
    return sorted(all_names_set, key=stackrox_sort_key if use_stackrox_sort_key else None)


def populate_ordered_entries(all_names, items):
    """Makes each item's ordered_entries to match the size and positions of elements in `all_names`."""
    for x in items:
        result = [None] * len(all_names)
        for y in x.unordered_entries:
            idx = all_names.index(y.name)
            result[idx] = y
        x.ordered_entries = result


def describe_git(dir):
    git_describe_run = subprocess.run([
        "git",
        "-C", dir,
        "describe", "--all", "--long", "--dirty"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
        encoding='utf-8')
    git_describe_output = "unknown commit"
    if git_describe_run.returncode == 0:
        git_describe_output = git_describe_run.stdout
    return git_describe_output


#### End of: Load and massage data
#########################################################


def render_title(data):
    return html.escape(f"Test matrix {data.target_repo} @ {data.git_describe_output}")


def render_summary_tables(data):
    with io.StringIO() as buffer:
        render_summary_tables_impl(buffer, data)
        return buffer.getvalue()


def render_summary_tables_impl(buffer, data):
    def emit(txt):
        buffer.write(txt)

    def write_tr(items, css_class=None):
        emit(f"""<tr class="{css_class}">""")
        for i in items:
            emit(i)
        emit("</tr>\n")

    #########################################################
    #### Presubmits

    emit(f"""
        <h4 id="presubmit-jobs-summary">Presubmit jobs summary
            <a class="anchor-link" href="#presubmit-jobs-summary">#</a>
        </h4>
        <p><code>{html.escape(data.jobs_dir_relative)}</code></p>
        <table
            class="table table-bordered table-hover table-striped disable-wrap sticky-header">
            <thead>
    """)

    write_tr([th("")] +
             [th(j.short_filename, css_class="natural-vertical-alignment rotatable-cell") for j in data.jobs_files])

    emit("""
            </thead>
            <tbody>
        """)

    write_tr([td("yaml loaded?", css_class="header-cell")] +
             [td(render_load_error(j.load_error), html_escape=False) for j in data.jobs_files])

    emit(f"""
            <tr><td class="header-cell">jobs</td><td colspan="{len(data.jobs_files)}"></td></tr>
        """)

    for i_row in range(len(data.all_job_names)):
        write_tr(
            [td(data.all_job_names[i_row], css_class="right-aligned")] +
            [td(render_job_entry(j.ordered_entries[i_row]), html_escape=False) for j in data.jobs_files])

    emit("""
            </tbody>
        </table>
        """)

    #### End of: Presubmits
    #########################################################

    #########################################################
    #### Configs

    emit(f"""
        <h4 id="config-summary">Config summary
            <a class="anchor-link" href="#config-summary">#</a>
        </h4>
        <p><code>{html.escape(data.config_dir_relative)}</code></p>
        <table
            class="table table-bordered table-hover table-striped disable-wrap sticky-header">
            <thead>
        """)

    write_tr([th("")] +
             [th(c.short_filename, css_class="natural-vertical-alignment rotatable-cell") for c in data.configs])

    emit("""
            </thead>
            <tbody>
        """)

    write_tr([td("yaml loaded?", css_class="header-cell")] +
             [td(render_load_error(c.load_error), html_escape=False) for c in data.configs])

    write_tr([td("branch", css_class="header-cell")] +
             [td(c.branch, css_class="vertical-text natural-vertical-alignment") for c in data.configs])

    write_tr([td("ocp release", css_class="header-cell")] +
             [render_vertically_collapsible_cell(c.ocp_release, c.dump_ocp_release()) for c in data.configs])

    write_tr([td("build root tag", css_class="header-cell")] +
             [render_vertically_collapsible_cell(c.build_root_tag, c.dump_build_root()) for c in data.configs])

    emit(f"""
            <tr><td class="header-cell">base images</td><td colspan="{len(data.configs)}"></td></tr>
        """)

    for i_row in range(len(data.all_base_image_names)):
        write_tr(
            [td(data.all_base_image_names[i_row], css_class="right-aligned")] +
            [render_base_image_entry(c.base_images.ordered_entries[i_row]) for c in data.configs])

    emit(f"""
            <tr><td class="header-cell">tests</td><td colspan="{len(data.configs)}"></td></tr>
        """)

    for i_row in range(len(data.all_test_names)):
        write_tr(
            [td(data.all_test_names[i_row], css_class="right-aligned")] +
            [td(render_test_entry(c.ordered_entries[i_row]), html_escape=False) for c in
             data.configs])

    emit("""
            </tbody>
        </table>
        """)

    #### End of: Configs
    #########################################################


def cell(tag, content, css_class=None, html_escape=True):
    return f"""<{tag} class="{css_class}"><div>{html.escape(content) if html_escape else content}</div></{tag}>"""


def th(content, css_class=None):
    return cell("th", content, css_class=css_class)


def td(content, css_class=None, html_escape=True):
    return cell("td", content, css_class=css_class, html_escape=html_escape)


def render_load_error(error):
    if error is None:
        return """<i class="bi bi-check" title="no error"></i>"""
    btn_text = """<i class="bi bi-bug-fill" title="YAML load error"></i>"""
    return render_icon_collapsible(btn_text, html.escape(str(error)))


def render_test_entry(entry):
    if entry is None:
        return ""
    yaml_dump = yaml.safe_dump(entry.raw_entry)
    btn_text = ""
    if entry.is_cron:
        btn_text += """<i class="bi bi-alarm" title="Cron"></i>"""
    if entry.is_postsubmit:
        btn_text += """<i class="bi bi-sign-merge-right" title="Postsubmit"></i>"""
    if entry.is_optional:
        btn_text += """<i class="bi bi-toggles" title="Optional"></i>"""
    if entry.has_run_if_changed:
        btn_text += """<i class="bi bi-funnel-fill" title="Run if changed"></i>"""
    if btn_text == "":
        btn_text = """<i class="bi bi-hand-thumbs-up" title="no interesting flags"></i>"""
    return render_icon_collapsible(btn_text, yaml_dump)


def render_job_entry(entry):
    if entry is None:
        return ""
    btn_text = f"""
        <span title="always_run: {entry.always_run}">ar:
            <i class="bi {"bi-toggle-on" if entry.always_run else "bi-toggle-off"}"></i>
        </span>
    """
    if entry.run_if_changed:
        btn_text += f"""
            <br><span title="run_if_changed: {entry.run_if_changed}">ric:
                <i class="bi bi-funnel-fill"></i>
            </span>
        """
    if entry.skip_if_only_changed:
        btn_text += f"""
            <br><span title="skip_if_only_changed: {entry.skip_if_only_changed}">sioc:
                <i class="bi bi-skip-forward-circle-fill"></i>
            </span>
        """

    return render_icon_collapsible(btn_text, entry.dump_all_interesting_attrs())


def render_icon_collapsible(button_text, contents):
    # This ensures each collapsible has a unique id because ids in HTML must be unique and besides that's how the button
    # knows what to expand and collapse.
    render_icon_collapsible.next_id = \
        (render_icon_collapsible.next_id if hasattr(render_icon_collapsible, "next_id") else 0) + 1
    id = f"collapse-id-{render_icon_collapsible.next_id}"

    return f"""
        <button
            class="btn btn-outline-primary btn-sm fs-5"
            type="button"
            data-bs-toggle="collapse"
            data-bs-target="#{id}"
            aria-expanded="false" aria-controls="{id}"
            title="Click to toggle contents display"
            >{button_text}</button><br>
        <div id="{id}" class="collapse">
            <pre>{html.escape(contents)}</pre>
        </div>
    """


def render_base_image_entry(entry):
    if not entry:
        return td("")
    return render_vertically_collapsible_cell(entry.tag, yaml.safe_dump(entry.raw_entry))


def render_vertically_collapsible_cell(short_text, details):
    if not short_text:
        return td("")
    return td(f"""
        {html.escape(short_text)}
        <div class="collapse">
            <pre>{html.escape(details)}</pre>
        </div>
        """, css_class="rotatable-cell natural-vertical-alignment", html_escape=False)


def render_doc(title, table_content):
    return page \
        .replace("HERE_GOES_TITLE", title) \
        .replace("HERE_GOES_THE_ACTUAL_CONTENT", table_content)


page = """
<!doctype html>
<html lang="en">
  <head>
    <!-- Meta tags required for Bootstrap -->
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">

    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet" integrity="sha384-9ndCyUaIbzAi2FUVXJi0CjmCapSmO7SnpJef0486qhLnuZ2cdeRhO02iuK6FUUVM" crossorigin="anonymous">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.10.5/font/bootstrap-icons.css">
    
    <!-- This page custom styles -->
    <style>
        .disable-wrap { white-space: nowrap; }
        .natural-vertical-alignment {
            vertical-align: bottom;
            text-align: left;
            min-width: 3em;
        }
        .vertical-text div {
            /* Credits to https://stackoverflow.com/a/47245068/484050 */
            -ms-writing-mode: tb-rl;
            -webkit-writing-mode: vertical-rl;
            writing-mode: vertical-rl;
            transform: rotate(180deg);
        }
        .vertical-text button {
            /* Makes icon-button look a bit more square when text is rotated. */
            padding-left: 4px;
            padding-right: 3px;
            padding-top: 8px;
            padding-bottom: 8px;
        }
        .sticky-header thead th {
            /* Credits to https://stackoverflow.com/a/49510703/484050 */
            position: sticky;
            top: 0;
            z-index: 10;
            background: white;
            border-width: 1;
        }
        .sticky-header thead th {
            /* Credits to https://stackoverflow.com/a/52256954/484050 */
            box-shadow: inset 0 1px 0 rgb(222, 226, 230), inset 0 -1px 0 rgb(222, 226, 230);
            background-clip: padding-box;
        }
        .right-aligned {
            text-align: right;
        }
        .collapsing {
            /* Set animation duration to zero otherwise collapsing collapsible is slow. */
            /* Credits to https://github.com/twbs/bootstrap/issues/31554#issuecomment-686726639 */
            transition-duration: 0s;
        }
        .header-cell {
            text-align:center;
            font-weight:bold;
        }
        .anchor-link {
            opacity: 0;
            transition: color 0.15s ease-in-out,opacity 0.15s ease-in-out;
            text-decoration: none;
        }
        .anchor-link:focus, .anchor-link:hover {
            opacity: 1;
        }
    </style>
    
    <title>HERE_GOES_TITLE</title>
  </head>
  <body>
    HERE_GOES_THE_ACTUAL_CONTENT

    <script src="https://code.jquery.com/jquery-3.7.0.min.js" integrity="sha256-2Pmvv0kuTBOenSvLm6bvfBSSHrUJ+3A7x6P5Ebd07/g=" crossorigin="anonymous"></script>
    <script src="https://cdn.jsdelivr.net/npm/@popperjs/core@2.11.8/dist/umd/popper.min.js" integrity="sha384-I7E8VVD/ismYTF4hNIPjVp/Zjvgyol6VFvRkX/vR+Vc4jQkC+hVqc2pM8ODewa9r" crossorigin="anonymous"></script>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.min.js" integrity="sha384-fbbOQedDUMZZ5KreZpsbe1LCZPVmfTnH7ois6mU1QK+m14rQ1l2bGBq41eYeM/fS" crossorigin="anonymous"></script>
    
    <!-- This page custom script -->
    <script>
        function toggleRotation(elt) {
            $(elt).toggleClass("vertical-text");
            let icon = $(elt).find("div button i");
            let collapsibles = $(elt).find(".collapse");
            if ($(elt).hasClass("vertical-text")) {
                icon.attr("class", "bi bi-arrows-expand");
                collapsibles.removeClass("show");
            } else {
                icon.attr("class", "bi bi-arrows-collapse");
                collapsibles.addClass("show");
            }
        }
    
        $(document).ready(function() {
            let rotatables = $(".rotatable-cell");
            rotatables.children("div").prepend('<button type="button" class="btn btn-outline-secondary btn-sm"><i></i></button> ');
            rotatables.each(function() { toggleRotation(this); });
            rotatables.find("div button").on("click", function() {
                toggleRotation($(this).closest(".rotatable-cell"));
            });
        });
    </script>
  </body>
</html>
"""


def write_summary(data, config_dir):
    table = render_summary_tables(data)
    title = render_title(data)
    doc_content = render_doc(title, table)

    output_file = config_dir / "summary.html"
    output_file.write_text(doc_content, encoding='utf-8')
    print(f"Summary written to {output_file}")


def check_configs(data):
    configs_ok = True

    for config in data.configs:
        # check config for master and the release template - could also cover
        # release branches if this check proves useful.
        if config.branch == 'master' or config.branch == 'release-x.y':
            if not check_config(config, data):
                configs_ok = False

    return configs_ok


def check_config(config, data):
    print(f'Checking config/ file: {config.short_filename}')

    config_ok = True

    for entry in config.unordered_entries:
        if entry.is_postsubmit or entry.is_cron:
            continue
        if not check_entry(entry, config, data):
            config_ok = False

    return config_ok


def check_entry(entry, config, data):
    entry_ok = True

    print(f'> Checking config/ job: {config.short_filename}/{entry.name}')

    if not entry.has_always_run and not entry.has_run_if_changed and not entry.has_skip_if_only_changed:
        check_error(f"One of always_run, run_if_changed or skip_if_only_changed should be set in config/")
        entry_ok = False

    name = entry.name if config.variant is None else f"{config.variant}-{entry.name}"
    job, job_file = find_job_for_entry(name, config.branch, data)
    if job is None:
        check_error(f"Cannot find a job/ file for {config.branch} {name}")            
        return False

    print(f'  With jobs/ job: {job_file.short_filename}/{job.name}')

    if entry.has_always_run and entry.always_run != job.always_run:
        check_error(f"There is a mismatch between always_run in config/ {entry.always_run} versus jobs/ {job.always_run}")
        entry_ok = False

    if entry.has_run_if_changed and entry.run_if_changed != job.run_if_changed:
        # `make jobs` will fix this, it takes the value of config/ as
        # authoritative.
        check_error(f"""There is a mismatch between run_if_changed in config/ versus jobs/
  {entry.run_if_changed}
  {job.run_if_changed}""")
        entry_ok = False
    elif job.has_run_if_changed and not entry.has_run_if_changed:
        check_error(f"""The value of run_if_changed should be reconciled with config/
  {job.run_if_changed}""")
        entry_ok = False

    if entry.has_skip_if_only_changed and entry.skip_if_only_changed != job.skip_if_only_changed:
        # `make jobs` will fix this, it takes the value of config/ as
        # authoritative.
        check_error(f"""There is a mismatch between skip_if_only_changed in config/ versus jobs/
  {entry.skip_if_only_changed}
  {job.skip_if_only_changed}""")
        entry_ok = False
    elif job.has_skip_if_only_changed and not entry.has_skip_if_only_changed:
        check_error(f"""The value of skip_if_only_changed should be reconciled with config/
  {job.skip_if_only_changed}""")
        entry_ok = False

    return entry_ok


def find_job_for_entry(name, branch, data):
    for job_file in data.jobs_files:
        if not job_file.short_filename.startswith(branch):
            continue
        for job in job_file.unordered_entries:
            if job.name == name:
                return job, job_file
    return None, None


def check_error(msg):
    print(f"ERROR: {msg}")


def main():
    parser = argparse.ArgumentParser(
                prog='config.py',
                description='Utility to help maintain CI configuration',
    )
    parser.add_argument('-s', '--summarize', help='generate a configuration summary in summary.html', action='store_true')
    parser.add_argument('-c', '--check', help='validate configuration against stackrox repo rules', action='store_true')
    args = parser.parse_args()

    config_dir = pathlib.Path(__file__).parent

    data = load_and_massage_data(config_dir)

    if args.summarize:
        write_summary(data, config_dir)

    if args.check:
        if not check_configs(data):
            print("""
A configuration error was found in one or more config/ or jobs/ files.
This script enforces the following rules for the stackrox/stackrox repo for
presubmit jobs:
- config/ jobs must have one of always_run, run_if_changed or skip_if_only_changed.
- The config/ and jobs/ values of always_run for a job must match. `make jobs`
  will not update this.
- The config/ and jobs/ values of run_if_changed and skip_if_only_changed for a job
  must match. `make jobs` will update config/ to jobs/ but it will not update config/
  from jobs/ if the value is not present in config/.
Ref: https://docs.ci.openshift.org/docs/architecture/ci-operator/#pre-submit-tests""")
            sys.exit(1)

    if not args.summarize and not args.check:
        parser.error('One of --summarize or --check is expected')


if __name__ == "__main__":
    main()
