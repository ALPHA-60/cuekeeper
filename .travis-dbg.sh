#!/bin/bash -ux
bash -ex .travis-opam.sh || echo Failed
cd /home/travis/.opam/system/build/mirage-block-unix.*
echo OUT
cat *.out
cat /home/travis/.opam/system/build/mirage-block-unix.*/_build/oUnit-*.log
echo ERR
cat *.err
exit 1
