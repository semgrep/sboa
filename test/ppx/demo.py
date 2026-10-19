import _demo

r = _demo.run(["/bin/echo", "hi"], verbose=True)
assert (r.output, r.exit_code, r.log) == ("/bin/echo hi", 0, "ran echo")
assert repr(r) == "RunResult(output='/bin/echo hi', exit_code=0, log='ran echo')"
assert r == _demo.RunResult("/bin/echo hi", 0, log="ran echo")
match r:
    case _demo.RunResult(output, 0, _):
        assert output == "/bin/echo hi"

try:
    _demo.run([])
except _demo.RunError as e:
    assert (e.message, e.exit_code) == ("nothing to run", 2)
    assert isinstance(e, _demo.OCamlError)
