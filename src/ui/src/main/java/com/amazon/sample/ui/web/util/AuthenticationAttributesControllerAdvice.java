/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of this
 * software and associated documentation files (the "Software"), to deal in the Software
 * without restriction, including without limitation the rights to use, copy, modify,
 * merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 * permit persons to whom the Software is furnished to do so.
 */

package com.amazon.sample.ui.web.util;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.util.Base64;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.server.reactive.ServerHttpRequest;
import org.springframework.web.bind.annotation.ControllerAdvice;
import org.springframework.web.bind.annotation.ModelAttribute;

@Slf4j
@ControllerAdvice
public class AuthenticationAttributesControllerAdvice {

  static final String OIDC_DATA_HEADER = "x-amzn-oidc-data";
  private static final int JWT_PART_COUNT = 3;

  private final ObjectMapper objectMapper;

  public AuthenticationAttributesControllerAdvice(ObjectMapper objectMapper) {
    this.objectMapper = objectMapper;
  }

  @ModelAttribute("authenticatedUsername")
  public String authenticatedUsername(ServerHttpRequest request) {
    String oidcData = request.getHeaders().getFirst(OIDC_DATA_HEADER);

    if (oidcData == null || oidcData.isBlank()) {
      return null;
    }

    try {
      String[] tokenParts = oidcData.split("\\.");
      if (tokenParts.length != JWT_PART_COUNT) {
        return null;
      }

      byte[] payload = Base64.getUrlDecoder().decode(tokenParts[1]);
      JsonNode claims = objectMapper.readTree(payload);

      return firstClaim(claims, "email", "username", "cognito:username");
    } catch (IllegalArgumentException | IOException exception) {
      log.debug("Unable to read ALB OIDC user claims", exception);
      return null;
    }
  }

  private String firstClaim(JsonNode claims, String... claimNames) {
    for (String claimName : claimNames) {
      String value = claims.path(claimName).asText("");
      if (!value.isBlank()) {
        return value;
      }
    }

    return null;
  }
}
