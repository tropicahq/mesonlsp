parsing_inc = include_directories('.')
parsing_dep = [ast_dep, utils_dep]
parsing_lib = static_library(
    'parsing',
    'lexer.cpp',
    'parser.cpp',
    include_directories: parsing_inc,
    dependencies: parsing_dep,
)
parsing_dep = declare_dependency(
    include_directories: parsing_inc,
    link_with: [parsing_lib],
    dependencies: parsing_dep,
)

executable(
    'lexingtool',
    'lexingtool.cpp',
    dependencies: [parsing_dep] + extra_deps + extra_libs,
)

executable(
    'lexerstats',
    'lexerstats.cpp',
    dependencies: [parsing_dep] + extra_deps + extra_libs,
)

executable(
    'parserstats',
    'parserstats.cpp',
    dependencies: [parsing_dep] + extra_deps + extra_libs,
)

executable(
    'parsingtool',
    'parsingtool.cpp',
    dependencies: [parsing_dep] + extra_deps + extra_libs,
)

executable(
    'parserbench',
    'parserbench.cpp',
    dependencies: [parsing_dep] + extra_deps + extra_libs,
)
