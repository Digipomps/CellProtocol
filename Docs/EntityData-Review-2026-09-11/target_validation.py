"""Draft 2020-12 validation with an explicit offline Ajv alternative.

Normally uses requirements-target.txt. If Python dependencies are unavailable,
set ENTITYDATA_AJV_MODULE to an installed ajv directory and
ENTITYDATA_AJV_FORMATS_MODULE to an installed ajv-formats directory. Node must
be on PATH. No downloads or silent fallback, and the selected engine is reported.
"""
import importlib.metadata
import json
import os
import subprocess
from types import SimpleNamespace

AJV_SCRIPT = r'''
const fs = require('fs');
const path = require('path');
const Ajv = require(path.join(process.env.ENTITYDATA_AJV_MODULE, 'dist/2020.js'));
const formats = require(process.env.ENTITYDATA_AJV_FORMATS_MODULE);
const ajv = new Ajv({allErrors: true, strict: false});
formats(ajv);
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
let valid;
let errors;
if (input.mode === 'schema') {
  valid = ajv.validateSchema(input.schema);
  errors = ajv.errors;
} else {
  const validate = ajv.compile(input.schema);
  valid = validate(input.data);
  errors = validate.errors;
}
console.log(JSON.stringify({valid, errors: errors || [],
  engine: 'Ajv ' + require(path.join(process.env.ENTITYDATA_AJV_MODULE, 'package.json')).version
    + ' + ajv-formats ' + require(path.join(process.env.ENTITYDATA_AJV_FORMATS_MODULE, 'package.json')).version}));
'''


def ajv_result(schema, mode, data=None):
    if not os.environ.get('ENTITYDATA_AJV_FORMATS_MODULE'):
        raise RuntimeError('ENTITYDATA_AJV_FORMATS_MODULE is required for format checks')
    result = subprocess.run(['node', '-e', AJV_SCRIPT],
                            input=json.dumps({'schema': schema, 'mode': mode, 'data': data}),
                            text=True, capture_output=True, check=True)
    return json.loads(result.stdout)


def engine():
    if os.environ.get('ENTITYDATA_AJV_MODULE'):
        return ajv_result({}, 'schema')['engine']
    return 'jsonschema ' + importlib.metadata.version('jsonschema')


def check_schema(schema):
    if os.environ.get('ENTITYDATA_AJV_MODULE'):
        result = ajv_result(schema, 'schema')
        if not result['valid']:
            raise ValueError(result['errors'])
    else:
        from jsonschema import Draft202012Validator
        Draft202012Validator.check_schema(schema)


def validation_errors(schema, data, subschema=None):
    if os.environ.get('ENTITYDATA_AJV_MODULE'):
        if subschema is not None:
            # All target refs are local #/$defs refs, verified by the validator.
            schema = {'$schema': schema['$schema'], '$defs': schema['$defs'], **subschema}
        result = ajv_result(schema, 'data', data)
        return [SimpleNamespace(validator=e['keyword'],
                                message=e['instancePath'] + ': ' + e['message']) for e in result['errors']]
    from jsonschema import Draft202012Validator, FormatChecker
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    if subschema is not None:
        validator = validator.evolve(schema=subschema)
    return list(validator.iter_errors(data))


def validate(schema, data):
    errors = validation_errors(schema, data)
    if errors:
        raise ValueError('; '.join(e.message for e in errors))
