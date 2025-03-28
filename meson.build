project(
    'mesonlsp',
    'c',
    'cpp',
    default_options: [
        'b_ndebug=if-release',
        'cpp_std=gnu++23',
        'warning_level=3',
    ],
    version: 'v4.3.7',
)

cc = meson.get_compiler('c')
cxx = meson.get_compiler('cpp')

buildtype = get_option('buildtype')
if buildtype != 'plain'
    if buildtype == 'release'
        extra_flags = ['-D_FORTIFY_SOURCE=3']
    else
        extra_flags = []
        add_global_arguments(
            ['-D_GLIBCXX_ASSERTIONS=1', '-D_GLIBCXX_DEBUG=1'],
            language: 'cpp',
        )
    endif

    extra_flags += [
        '-fstack-protector-strong',
        '-g3',
        '-ftrivial-auto-var-init=zero',
        '-Wuninitialized',
        '-Wno-keyword-macro',
    ]

    if cc.get_id() == 'gcc'
        extra_flags += [
            '-Wshadow=local',
            '-fstack-clash-protection',
        ]
    endif

    if host_machine.system() == 'linux'
        extra_flags += [
            '-frecord-gcc-switches',
        ]
        extra_flags += cc.get_supported_arguments(
            '-mshstk',
            '-fcf-protection=full',
            '-Wnrvo',
        )
    endif

    global_link_args = host_machine.system() == 'windows' ? [] : ['-rdynamic']
    if host_machine.system() == 'linux'
        global_link_args += ['-Wl,-z,relro,-z,now']
    elif host_machine.system() == 'darwin'
        global_link_args += ['-Wl,-ld_classic']
    endif

    add_global_arguments(extra_flags, language: ['c', 'cpp'])
    add_global_link_arguments(global_link_args, language: ['c', 'cpp'])
endif

if not get_option('use_own_tree_sitter')
    tree_sitter_dep = dependency(
        'tree-sitter',
        required: false,
        static: true,
        fallback: [],
    )
else
    tree_sitter_proj = subproject(
        'tree-sitter',
        default_options: ['default_library=static'],
    )
    tree_sitter_dep = tree_sitter_proj.get_variable('tree_sitter_dep')
    meson.override_dependency('tree-sitter', tree_sitter_dep)
endif

tree_sitter_meson_proj = subproject(
    'tree-sitter-meson',
    default_options: ['default_library=static'],
)
tree_sitter_meson_dep = tree_sitter_meson_proj.get_variable(
    'tree_sitter_meson_dep',
)

tree_sitter_ini_proj = subproject(
    'tree-sitter-ini',
    default_options: ['default_library=static'],
)
tree_sitter_ini_dep = tree_sitter_ini_proj.get_variable('tree_sitter_ini_dep')
sha256_proj = subproject('sha256', default_options: ['default_library=static'])
sha256_dep = sha256_proj.get_variable('sha256_dep')

ada_proj = subproject('ada', default_options: ['default_library=static'])
ada_dep = ada_proj.get_variable('ada_dep')

muon_proj = subproject('muon')
muon_dep = muon_proj.get_variable('muon_dep')

nlohmann_json_dep = dependency('nlohmann_json')
curl_dep = dependency('libcurl')
archive_dep = dependency('libarchive')
uuid_dep = dependency('uuid', required: target_machine.system() != 'windows')
pkgconf_dep = dependency('libpkgconf')

cc_id = cc.get_id()
if cc_id != 'gcc' and cc_id != 'clang'
    warning(f'Unknown compiler: @cc_id@')
endif

args = []

if get_option('static_build')
    extra_deps = [
        dependency('libbrotlicommon'),
        dependency('libbrotlidec'),
        dependency('libbrotlienc'),
        dependency('liblzma'),
        dependency('zlib'),
    ]
    jemalloc_dep = dependency('jemalloc', static: true, required: false)
    if jemalloc_dep.found()
        extra_deps += jemalloc_dep
    else
        warning('jemalloc wasn\'t found')
    endif
    extra_libs = [cxx.find_library('c'), cxx.find_library('unistring')]
    extra_link_args = ['-static', '-Wl,-wrap=__cxa_throw']
else
    extra_deps = []
    extra_libs = []
    extra_link_args = []
    if get_option('use_jemalloc')
        extra_deps += dependency('jemalloc', static: true)
        args += '-DUSE_JEMALLOC'
    elif get_option('use_mimalloc')
        if get_option('use_mimalloc_wrap')
            mimalloc_proj = subproject('mimalloc')
            extra_deps += mimalloc_proj.get_variable('mimalloc_dep')
        else
            extra_deps += dependency('mimalloc', static: true)
        endif
        args += '-DUSE_MIMALLOC'
    endif
endif

fmt_dep = []
if target_machine.system() == 'darwin'
    fmt_dep = [dependency('fmt', static: true)]
    extra_deps += fmt_dep
endif

gtest_dep = dependency('gtest', main: true, required: false)

subdir('src')

if not gtest_dep.found() and get_option('tests')
    gtest_proj = subproject('gtest')
    gtest_dep = gtest_proj.get_variable('gtest_dep')
endif

if gtest_dep.found() and get_option('tests')
    subdir('tests')
endif

py_mod = import('python')
py_installation = py_mod.find_installation(
    modules: ['pygls', 'lsprotocol'],
    required: false,
)

if get_option('tests') and py_installation.found()
    subdir('LSPTests')
endif
