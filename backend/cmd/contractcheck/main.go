package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/getkin/kin-openapi/openapi3"
	"github.com/santhosh-tekuri/jsonschema/v6"
)

func main() {
	path := "../contracts/openapi/flow.yaml"
	if len(os.Args) == 2 {
		path = os.Args[1]
	}
	loader := openapi3.NewLoader()
	doc, err := loader.LoadFromFile(path)
	if err == nil {
		err = doc.Validate(context.Background())
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("OpenAPI válido")
	base := filepath.Dir(filepath.Dir(path))
	for _, name := range []string{"events", "realtime"} {
		file := filepath.Join(base, name, "envelope.schema.json")
		if err := validateSchema(file); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Println("JSON Schema válido:", name)
	}
	if err := validateSchema(filepath.Join(base, "events", "experience-payload.schema.json")); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("JSON Schema válido: experience lifecycle payload v1")
}

func validateSchema(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	doc, err := jsonschema.UnmarshalJSON(f)
	if err != nil {
		return err
	}
	compiler := jsonschema.NewCompiler()
	compiler.DefaultDraft(jsonschema.Draft2020)
	compiler.AssertFormat()
	absolute, err := filepath.Abs(path)
	if err != nil {
		return err
	}
	if err := compiler.AddResource(absolute, doc); err != nil {
		return err
	}
	_, err = compiler.Compile(absolute)
	return err
}
